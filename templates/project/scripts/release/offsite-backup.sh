#!/usr/bin/env bash
# scripts/release/offsite-backup.sh — trigger one off-site dump NOW (ops/08
# step 9, ops/09). The release closes with a fresh dump on the Storage Box.
#
# Mechanism: the stack's backup sidecar already owns the whole off-site
# contract (pg_dump -Fc validated with pg_restore --list, SFTP port 23 with
# the dedicated key, rotation local + remote). This script just runs ONE
# cycle of it via `docker exec -e RUN_ONCE=1` — the upload happens FROM THE
# NODE, where port 23 is reachable (operator networks often block it).
#
# Usage: offsite-backup.sh [production|preview]   (default: production)
#
# Exit contract:
#   0 — dump created and validated (upload result may still be a WARN: a
#       failed upload keeps the local copy and retries at the daily cycle),
#       OR the sidecar is absent (WARN — the release is not blocked by it)
#   1 — the dump itself failed inside the sidecar (that IS a problem)
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "${FORJA_ROOT}"

env_ctx "${1:-production}"

cid="$(service_container_id backup)"
if [ -z "${cid}" ]; then
  warn "backup sidecar ${STACK}_backup is not running — off-site dump skipped (deploy the stack first; WARN, not fatal)"
  exit 0
fi

log "running one backup cycle in ${STACK}_backup (docker exec, RUN_ONCE=1)"
out=""
if out="$(dk exec -e RUN_ONCE=1 "${cid}" /usr/local/bin/db-backup.sh 2>&1)"; then
  printf '%s\n' "${out}"
  # db-backup.sh logs `... [ok] uploaded: <file> -> <dest>:<remote-dir>/<file>`
  uploaded="$(printf '%s\n' "${out}" | awk '$2 == "[ok]" && $3 == "uploaded:" { print $4; exit }')"
  if [ -n "${uploaded}" ]; then
    pass "off-site dump uploaded: ${uploaded}"
  else
    warn "dump created and validated, but the upload did not complete (missing storage_box_dest/backup_ssh_key_b64 or SFTP failure) — the local copy stays; the sidecar retries at 03:30 UTC"
  fi
  exit 0
else
  printf '%s\n' "${out}" >&2
  fail "the backup cycle failed inside ${STACK}_backup — the dump itself did not validate"
fi
