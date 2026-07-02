#!/bin/bash
# scripts/db-backup.sh — backup sidecar entrypoint (doctrine: wiki ops/09).
# Runs as the `backup` service of the stack (Dockerfile stage `backup`,
# FROM postgres:<same-major-as-db> + openssh-client, USER postgres).
#
# Daily mode (default, the service entrypoint):
#   - ONE backup cycle immediately on start (a restart never skips a day),
#   - then a cycle at every 03:30 UTC. Mechanism: a sleep-loop — the epoch
#     for today's 03:30 UTC is computed with GNU date; if it already passed,
#     +86400s; sleep runs in the BACKGROUND with `wait` so SIGTERM stops the
#     container promptly instead of blocking on a day-long sleep.
#
# One cycle:
#   1. pg_dump -Fc to a hidden .part file in /backups
#   2. guards: the dump must be NON-EMPTY and `pg_restore --list` must read
#      it — an invalid dump is DELETED and never rotated in (an empty or
#      corrupt dump is not a backup)
#   3. rename into /backups/<db>_<utc-ts>.dump (now part of the rotation set)
#   4. local rotation: keep the newest $BACKUP_KEEP dumps in the volume
#   5. off-site: SFTP (port 23, batch mode) to $BACKUP_REMOTE_DIR on the
#      Storage Box with the DEDICATED sidecar key (secret backup_ssh_key_b64,
#      base64 -> decoded at start to a 600-perm file); then remote rotation
#      to $BACKUP_KEEP. A failed upload is a WARN — the local copy already
#      rotated in, and the next cycle retries. Local rotation never depends
#      on remote success.
#
# RUN_ONCE=1: run a single cycle and exit — used by
# scripts/release/offsite-backup.sh via
#   docker exec -e RUN_ONCE=1 <backup-cid> /usr/local/bin/db-backup.sh
# Exit code in RUN_ONCE mode: 0 = dump created AND validated (the upload may
# still be a WARN); non-zero = the dump itself failed.
#
# Env (wired by stack.yml): PGHOST PGPORT PGUSER PGDATABASE
#   DB_PASSWORD_FILE (default /run/secrets/db_password)
#   BACKUP_KEEP (default 7)  BACKUP_REMOTE_DIR (e.g. backups/<stack>/daily)
# Secrets: /run/secrets/storage_box_dest  /run/secrets/backup_ssh_key_b64
# Volume:  /backups
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
BACKUP_REMOTE_DIR="${BACKUP_REMOTE_DIR:-}"
DB_PASSWORD_FILE="${DB_PASSWORD_FILE:-/run/secrets/db_password}"
DEST_FILE="${DEST_FILE:-/run/secrets/storage_box_dest}"
KEY_B64_FILE="${KEY_B64_FILE:-/run/secrets/backup_ssh_key_b64}"
SSH_KEY_FILE="${SSH_KEY_FILE:-/tmp/backup_ssh_key}"

ts()   { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
info() { printf '%s [info] %s\n' "$(ts)" "$*"; }
ok()   { printf '%s [ok] %s\n' "$(ts)" "$*"; }
wrn()  { printf '%s [warn] %s\n' "$(ts)" "$*"; }
err()  { printf '%s [error] %s\n' "$(ts)" "$*" >&2; }

# ── Preconditions ────────────────────────────────────────────────────────────
for v in PGHOST PGUSER PGDATABASE; do
  if [ -z "${!v:-}" ]; then
    err "missing required env: ${v}"
    exit 1
  fi
done
PGPORT="${PGPORT:-5432}"
[ -d "${BACKUP_DIR}" ] || { err "backup dir ${BACKUP_DIR} does not exist"; exit 1; }
[ -r "${DB_PASSWORD_FILE}" ] || { err "cannot read DB_PASSWORD_FILE (${DB_PASSWORD_FILE})"; exit 1; }
PGPASSWORD="$(cat "${DB_PASSWORD_FILE}")"
export PGPASSWORD PGHOST PGPORT PGUSER PGDATABASE

# ── Off-site configuration (dedicated key, decoded once at start) ────────────
REMOTE_ENABLED=0
DEST=""
if [ -r "${DEST_FILE}" ] && [ -r "${KEY_B64_FILE}" ]; then
  DEST="$(tr -d '[:space:]' < "${DEST_FILE}")"
  if [ -z "${DEST}" ]; then
    wrn "storage_box_dest secret is empty — off-site upload disabled"
  elif (umask 077; base64 -d "${KEY_B64_FILE}" > "${SSH_KEY_FILE}") 2>/dev/null && [ -s "${SSH_KEY_FILE}" ]; then
    # 600-perm private key: written under umask 077, never logged.
    REMOTE_ENABLED=1
  else
    rm -f "${SSH_KEY_FILE}"
    wrn "backup_ssh_key_b64 did not decode to a key file — off-site upload disabled"
  fi
else
  wrn "off-site upload disabled: storage_box_dest / backup_ssh_key_b64 secret not available (local-only mode)"
fi
if [ "${REMOTE_ENABLED}" = "1" ] && [ -z "${BACKUP_REMOTE_DIR}" ]; then
  wrn "BACKUP_REMOTE_DIR is empty — off-site upload disabled"
  REMOTE_ENABLED=0
fi

# ── SFTP helpers (port 23; batch mode; dedicated key) ────────────────────────
sftp_batch() { # $1 = batch file
  sftp -P 23 -i "${SSH_KEY_FILE}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/tmp/known_hosts \
    -o ConnectTimeout=20 \
    -b "$1" "${DEST}"
}

upload_dump() { # $1 = local dump path -> 0 on success
  local file name batch remaining component prefix
  file="$1"
  name="$(basename "${file}")"
  batch="$(mktemp)"
  {
    # Build the remote dir chain; -mkdir tolerates "already exists".
    remaining="${BACKUP_REMOTE_DIR}"
    prefix=""
    while [ -n "${remaining}" ]; do
      component="${remaining%%/*}"
      if [ "${component}" = "${remaining}" ]; then remaining=""; else remaining="${remaining#*/}"; fi
      [ -n "${component}" ] || continue
      if [ -n "${prefix}" ]; then prefix="${prefix}/${component}"; else prefix="${component}"; fi
      printf -- '-mkdir %s\n' "${prefix}"
    done
    printf 'put %s %s/%s\n' "${file}" "${BACKUP_REMOTE_DIR}" "${name}"
  } > "${batch}"
  if sftp_batch "${batch}" >/dev/null; then
    rm -f "${batch}"
    return 0
  fi
  rm -f "${batch}"
  return 1
}

rotate_remote() { # keep the newest $BACKUP_KEEP *.dump remotely -> 0 on success
  local batch listing count prune
  batch="$(mktemp)"
  printf 'ls -1 %s\n' "${BACKUP_REMOTE_DIR}" > "${batch}"
  listing="$(sftp_batch "${batch}" 2>/dev/null | awk -F/ '/\.dump$/ { print $NF }' | sort)" || listing=""
  rm -f "${batch}"
  [ -n "${listing}" ] || return 0
  count="$(printf '%s\n' "${listing}" | wc -l | tr -d '[:space:]')"
  [ "${count}" -gt "${BACKUP_KEEP}" ] || return 0
  prune=$(( count - BACKUP_KEEP ))
  batch="$(mktemp)"
  printf '%s\n' "${listing}" | head -n "${prune}" \
    | while IFS= read -r n; do printf 'rm %s/%s\n' "${BACKUP_REMOTE_DIR}" "${n}"; done > "${batch}"
  if sftp_batch "${batch}" >/dev/null; then
    rm -f "${batch}"
    info "remote rotation: pruned ${prune} old dump(s), keep ${BACKUP_KEEP}"
    return 0
  fi
  rm -f "${batch}"
  return 1
}

rotate_local() { # keep the newest $BACKUP_KEEP *.dump in $BACKUP_DIR
  local count prune
  count="$(find "${BACKUP_DIR}" -maxdepth 1 -type f -name '*.dump' | wc -l | tr -d '[:space:]')"
  [ "${count}" -gt "${BACKUP_KEEP}" ] || return 0
  prune=$(( count - BACKUP_KEEP ))
  # Names embed the UTC timestamp, so lexical sort == chronological order.
  find "${BACKUP_DIR}" -maxdepth 1 -type f -name '*.dump' | sort | head -n "${prune}" \
    | while IFS= read -r f; do
        rm -f "${f}"
        info "local rotation: pruned $(basename "${f}") (keep ${BACKUP_KEEP})"
      done
}

# ── One backup cycle ─────────────────────────────────────────────────────────
run_cycle() {
  local stamp name tmp final size
  stamp="$(date -u '+%Y%m%d-%H%M%S')"
  name="${PGDATABASE}_${stamp}.dump"
  tmp="${BACKUP_DIR}/.${name}.part"
  final="${BACKUP_DIR}/${name}"

  info "dump start: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE} -> ${name}"
  if ! pg_dump -Fc --no-password --file "${tmp}" "${PGDATABASE}"; then
    err "pg_dump failed"
    rm -f "${tmp}"
    return 1
  fi
  if [ ! -s "${tmp}" ]; then
    err "dump is EMPTY — an empty dump is not a backup; discarded"
    rm -f "${tmp}"
    return 1
  fi
  # The guard that matters: a dump pg_restore cannot list is NOT rotated in.
  if ! pg_restore --list "${tmp}" >/dev/null 2>&1; then
    err "dump failed pg_restore --list validation — corrupt dump discarded, NOT rotated in"
    rm -f "${tmp}"
    return 1
  fi
  size="$(du -h "${tmp}" | awk '{print $1}')"
  mv "${tmp}" "${final}"
  ok "dump validated: ${name} (${size}, pg_restore --list clean)"

  # Local rotation happens regardless of what the upload does next.
  rotate_local

  if [ "${REMOTE_ENABLED}" = "1" ]; then
    if upload_dump "${final}"; then
      ok "uploaded: ${name} -> ${DEST}:${BACKUP_REMOTE_DIR}/${name}"
      rotate_remote || wrn "remote rotation failed (will retry next cycle)"
    else
      wrn "upload failed: ${name} stays local; retry at the next daily cycle (03:30 UTC)"
    fi
  else
    wrn "upload skipped: off-site not configured (storage_box_dest / backup_ssh_key_b64)"
  fi
  return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────
if [ "${REMOTE_ENABLED}" = "1" ]; then
  remote_label="${DEST}:${BACKUP_REMOTE_DIR}"
else
  remote_label="disabled"
fi
info "db-backup sidecar: db=${PGDATABASE}@${PGHOST}:${PGPORT} keep=${BACKUP_KEEP} remote=${remote_label} mode=$([ "${RUN_ONCE:-0}" = "1" ] && printf 'one-shot' || printf 'daily')"

if [ "${RUN_ONCE:-0}" = "1" ]; then
  if run_cycle; then exit 0; else exit 1; fi
fi

trap 'info "stop signal received — exiting"; exit 0' TERM INT

# One run on start: a fresh deploy or a restart is never a skipped day.
run_cycle || wrn "cycle failed — next attempt at 03:30 UTC"

while :; do
  now="$(date -u +%s)"
  target="$(date -u -d "$(date -u '+%Y-%m-%d') 03:30:00" +%s)"
  if [ "${target}" -le "${now}" ]; then
    target=$(( target + 86400 ))
  fi
  info "sleeping $(( target - now ))s until $(date -u -d "@${target}" '+%Y-%m-%dT%H:%MZ')"
  sleep $(( target - now )) &
  wait $! || true
  run_cycle || wrn "cycle failed — next attempt at the next 03:30 UTC"
done
