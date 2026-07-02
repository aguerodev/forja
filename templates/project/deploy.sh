#!/usr/bin/env bash
# deploy.sh — deploy the stack to one environment, in five gated phases.
# (doctrine: wiki ops/06 — load `forja:doctrina`, recipe `desplegar`.
#  This is the canonical deploy mechanism; in production it is DRIVEN by
#  /forja:deploy, which adds preflight, off-site backup and rollback.)
#
# Usage:
#   ./deploy.sh prod     # server swarm via docker context <app>-prod
#   ./deploy.sh test     # LOCAL swarm (DOCKER_CONTEXT is deliberately unset)
#
# The five phases:
#   1. build    three images from ONE Dockerfile via --target
#               (runner -> <app>:latest, migrator -> <app>:migrate,
#                backup -> <app>:backup), no intermediate registry
#   2. secrets  materialize each key of secrets/<env>.env as ${STACK}_<key>
#               ONLY if absent (a live secret is never overwritten), then
#               HARD-assert ALL REQUIRED_SECRETS exist — a missing secret
#               aborts HERE, not with the schema already migrated
#   3. backup   (prod only) pre-migration pg_dump -Fc from the db container,
#               validated with pg_restore --list; an existing db with no
#               dump, an empty dump or an invalid dump ABORTS the deploy
#               before any stack change — no restore point, no migration
#   4. deploy   docker stack deploy + gated migrate job: the TASK STATE is
#               the only arbiter (Complete continues, Failed/Rejected
#               aborts) — CLI convergence is never trusted for a one-shot
#               job. On the local mutable-tag path (:latest) the app service
#               is force-rolled (the digest does not change otherwise).
#   5. health   node-side probe is FATAL and authoritative (docker exec in
#               the app task -> http://127.0.0.1:8000/api/health); the
#               public edge probe is WARN-only (it fuses app/tunnel/
#               Cloudflare failure domains). After a HEALTHY deploy the app
#               image is tagged <env>-<utc-ts> (+ v<version> in prod) and
#               the <env>-* history is pruned to the last 5.
#
# Env flags:
#   SKIP_BUILD=1       CI-style run: requires prebuilt APP_IMAGE and
#                      MIGRATE_IMAGE refs (BACKUP_IMAGE optional)
#   SKIP_SECRETS=1     skip materialization from secrets/<env>.env
#                      (the REQUIRED_SECRETS assert still runs)
#   MIGRATE_TIMEOUT    seconds to wait for the migrate job (default 300)
#   HEALTH_TIMEOUT     seconds for the node-side health window (default 90)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/lib.sh
source "${SCRIPT_DIR}/scripts/release/lib.sh"
require_cmd git
cd "${FORJA_ROOT}"

usage() {
  printf 'Usage: ./deploy.sh <prod|test>\n' >&2
  exit 2
}

case "${1:-}" in
  prod|production)
    env_ctx production
    ENV_FILE="secrets/prod.env"
    ;;
  test|preview)
    env_ctx preview
    ENV_FILE="secrets/test.env"
    # Single-connector rule (ops/06): one tunnel serves from ONE place at a
    # time. If this environment was ever deployed on the server, take it
    # down there first (stack AND secrets) or the two connectors will fight.
    warn "single-connector rule: make sure ${STACK} is NOT also running on the server (docker --context ${DOCKER_CONTEXT_PROD} stack ls)"
    ;;
  *) usage ;;
esac

[ -f "stack.yml" ]   || fail "stack.yml not found at ${FORJA_ROOT}"
[ -f "Dockerfile" ]  || fail "Dockerfile not found at ${FORJA_ROOT}"
if [ "${ENV_NAME}" = "production" ]; then
  docker context inspect "${DOCKER_CONTEXT_PROD}" >/dev/null 2>&1 \
    || fail "docker context '${DOCKER_CONTEXT_PROD}' does not exist — create it: docker context create ${DOCKER_CONTEXT_PROD} --docker host=ssh://deploy@<IP>"
fi

log "deploying ${STACK} (${ENV_NAME}) — context: ${DOCKER_CONTEXT:-local engine}"

# ── Phase 1/5: build ─────────────────────────────────────────────────────────
GIT_SHA="$(git rev-parse HEAD 2>/dev/null || printf '')"
if [ "${SKIP_BUILD:-0}" = "1" ]; then
  log "phase 1/5 build: SKIPPED (SKIP_BUILD=1 — CI path expects prebuilt refs)"
  [ -n "${APP_IMAGE:-}" ]     || fail "SKIP_BUILD=1 requires an explicit APP_IMAGE ref"
  [ -n "${MIGRATE_IMAGE:-}" ] || fail "SKIP_BUILD=1 requires an explicit MIGRATE_IMAGE ref"
  [ -n "${BACKUP_IMAGE:-}" ]  || warn "no BACKUP_IMAGE — stack.yml defaults to ${APP}:backup, which must already exist on the node"
else
  log "phase 1/5 build: three images from one Dockerfile (GIT_SHA=${GIT_SHA:-none})"
  dk build --target runner   --build-arg GIT_SHA="${GIT_SHA}" -t "${APP}:latest"  .
  dk build --target migrator -t "${APP}:migrate" .
  dk build --target backup   -t "${APP}:backup"  .
fi

# stack.yml substitutes these from the calling environment.
export STACK
export APP_IMAGE="${APP_IMAGE:-${APP}:latest}"
export MIGRATE_IMAGE="${MIGRATE_IMAGE:-${APP}:migrate}"
export BACKUP_IMAGE="${BACKUP_IMAGE:-${APP}:backup}"

# ── Phase 2/5: secrets ───────────────────────────────────────────────────────
if [ "${SKIP_SECRETS:-0}" = "1" ]; then
  log "phase 2/5 secrets: materialization SKIPPED (SKIP_SECRETS=1)"
elif [ -f "${ENV_FILE}" ]; then
  log "phase 2/5 secrets: materializing ${ENV_FILE} as ${STACK}_<key> (existing secrets are never overwritten)"
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in ''|\#*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    if [ -z "${key}" ] || [ "${key}" = "${line}" ]; then
      # Never echo the line itself: a malformed line may BE a secret value.
      warn "  skipping malformed line in ${ENV_FILE} (expected key=value)"
      continue
    fi
    secret_name="${STACK}_${key}"
    if dk secret inspect "${secret_name}" >/dev/null 2>&1; then
      log "  ${secret_name} exists — left untouched (secrets are immutable)"
    else
      printf '%s' "${value}" | dk secret create "${secret_name}" - >/dev/null
      log "  ${secret_name} created"
    fi
  done < "${ENV_FILE}"
else
  log "phase 2/5 secrets: no ${ENV_FILE} — assuming secrets are already bootstrapped in the swarm"
fi

# HARD assert: every required secret exists BEFORE touching the database.
swarm_secrets="$(dk secret ls --format '{{.Name}}')" \
  || fail "cannot list secrets on the ${ENV_NAME} engine"
missing=""
for s in ${REQUIRED_SECRETS}; do
  printf '%s\n' "${swarm_secrets}" | grep -qx "${STACK}_${s}" || missing="${missing} ${s}"
done
[ -z "${missing}" ] \
  || fail "missing required secrets for ${STACK}:${missing} — bootstrap them in ${ENV_FILE} and re-run (aborting BEFORE any stack change)"
pass "all required secrets present (${STACK}_*)"

# ── Phase 3/5: pre-migration backup (prod only) ──────────────────────────────
if [ "${ENV_NAME}" = "production" ]; then
  if dk service inspect "${STACK}_db" >/dev/null 2>&1; then
    log "phase 3/5 backup: pre-migration restore point from ${STACK}_db"
    db_cid=""
    deadline=$(( $(date +%s) + 30 ))
    while :; do
      db_cid="$(service_container_id db)"
      [ -n "${db_cid}" ] && break
      [ "$(date +%s)" -lt "${deadline}" ] \
        || fail "db service exists but no running container appeared — no restore point, no migration (aborting)"
      sleep 3
    done
    mkdir -p backups
    dump="backups/${STACK}_$(utc_ts).dump"
    dk exec "${db_cid}" pg_dump -U "${DB_USER}" -Fc "${DB_NAME}" > "${dump}" \
      || fail "pg_dump failed — no restore point, no migration (aborting)"
    # An empty dump is not a backup; a dump pg_restore cannot list is not a
    # backup. Either one aborts BEFORE any stack change.
    [ -s "${dump}" ] || fail "pre-migration dump is EMPTY (${dump}) — aborting"
    dk exec -i "${db_cid}" pg_restore --list < "${dump}" >/dev/null \
      || fail "pre-migration dump does not validate with pg_restore --list (${dump}) — aborting"
    pass "restore point: ${dump} (validated with pg_restore --list)"
  else
    log "phase 3/5 backup: first deploy of ${STACK} — no db service yet, nothing to back up"
  fi
else
  log "phase 3/5 backup: skipped (${ENV_NAME} — pre-migration backup is prod-only)"
fi

# ── Phase 4/5: stack deploy + gated migration ────────────────────────────────
# Capture the newest migrate task BEFORE deploying: on a redeploy the gate must
# judge the NEW job task, never the previous release's Complete (task creation
# is asynchronous to `stack deploy` returning).
prev_migrate_task="$(dk service ps "${STACK}_migrate" -q 2>/dev/null | head -n 1 || true)"

log "phase 4/5 deploy: docker stack deploy -c stack.yml ${STACK}"
dk stack deploy -c stack.yml "${STACK}"

# The migrate job result is read from the TASK STATE, never inferred from CLI
# blocking (a one-shot job never "converges"; doctrine ops/08, verified
# incident). docker service ps lists the newest task first; the gate only
# evaluates a task whose ID differs from the pre-deploy snapshot.
MIGRATE_TIMEOUT="${MIGRATE_TIMEOUT:-300}"
log "gating on ${STACK}_migrate task state (timeout ${MIGRATE_TIMEOUT}s)"
deadline=$(( $(date +%s) + MIGRATE_TIMEOUT ))
state=""
while :; do
  task_line="$(dk service ps "${STACK}_migrate" --format '{{.ID}} {{.CurrentState}}' 2>/dev/null \
    | head -n 1 || true)"
  task_id="${task_line%% *}"
  if [ -n "${task_id}" ] && [ "${task_id}" != "${prev_migrate_task}" ]; then
    state="$(printf '%s\n' "${task_line}" | awk '{print $2}')"
    case "${state}" in
      Complete)
        pass "migrate job Complete"
        break
        ;;
      Failed|Rejected)
        fail_line "migrate job ${state} — last logs:"
        dk service logs --raw --tail 50 "${STACK}_migrate" >&2 || true
        fail "migration failed; the pre-migration dump in backups/ is the restore point"
        ;;
      *) : ;;  # Pending/Running/Preparing — keep polling
    esac
  fi
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    fail_line "migrate job did not reach Complete within ${MIGRATE_TIMEOUT}s (last state: ${state:-new task not visible yet})"
    dk service ps "${STACK}_migrate" >&2 || true
    fail "migration gate timed out"
  fi
  sleep 5
done

# Local mutable-tag path: :latest keeps its digest, so stack deploy alone
# would not replace the running container — force the roll (start-first +
# failure_action: rollback still govern it).
if [ "${SKIP_BUILD:-0}" != "1" ] && [ "${APP_IMAGE}" = "${APP}:latest" ]; then
  log "forcing app roll (mutable :latest — digest unchanged, stack deploy alone would not replace it)"
  dk service update --force "${STACK}_app"
fi

# ── Phase 5/5: health ────────────────────────────────────────────────────────
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
log "phase 5/5 health: node-side probe (FATAL, authoritative; window ${HEALTH_TIMEOUT}s)"
if body="$(wait_node_health "${HEALTH_TIMEOUT}")"; then
  pass "node-side health 200 (buildSha $(json_field "${body}" buildSha), db $(json_field "${body}" db))"
else
  fail_line "node-side health did not turn 200 within ${HEALTH_TIMEOUT}s"
  dk service ps "${STACK}_app" >&2 || true
  dk service logs --raw --tail 50 "${STACK}_app" >&2 || true
  fail "deploy is NOT healthy — /forja:rollback ${ENV_NAME} lists known-good versions"
fi

# Edge probe: WARN-only. 530=cloudflared, 502=app, and Cloudflare fuses the
# failure domains — a connector transient must never sink a healthy deploy.
edge_code=""
edge_ok=0
for _try in 1 2 3; do
  edge_code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://${PUBLIC_HOST}/api/health" || true)"
  if [ "${edge_code}" = "200" ]; then
    edge_ok=1
    break
  fi
  sleep 5
done
if [ "${edge_ok}" = "1" ]; then
  pass "edge https://${PUBLIC_HOST}/api/health -> 200"
else
  warn "edge probe not 200 (last: ${edge_code:-000}) — WARN only: node-side already validated; check the tunnel if it persists"
fi

# ── Rollback tags: only a version that arrived HEALTHY enters the history ────
rollback_tag="${TAG_PREFIX}-$(utc_ts)"
dk image tag "${APP_IMAGE}" "${APP}:${rollback_tag}"
log "rollback tag: ${APP}:${rollback_tag}"
if [ "${ENV_NAME}" = "production" ]; then
  version="$(pkg_version)"
  dk image tag "${APP_IMAGE}" "${APP}:v${version}"
  log "rollback tag: ${APP}:v${version}"
fi

# Keep the last 5 <env>-* tags on the node; older ones are untagged.
old_tags="$(dk image ls --format '{{.Tag}}' "${APP}" | grep -E "^${TAG_PREFIX}-" | sort -r | tail -n +6 || true)"
if [ -n "${old_tags}" ]; then
  printf '%s\n' "${old_tags}" | while IFS= read -r t; do
    [ -n "${t}" ] || continue
    if dk image rm "${APP}:${t}" >/dev/null 2>&1; then
      log "pruned old rollback tag ${APP}:${t}"
    else
      warn "could not prune old rollback tag ${APP}:${t}"
    fi
  done
fi

pass "deploy of ${STACK} complete — https://${PUBLIC_HOST}"
