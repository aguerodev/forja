#!/usr/bin/env bash
# scripts/release/rollback-to.sh — software-plane rollback (ops/08).
# Re-points the app service to a previously deployed image tag and waits for
# health. CODE ONLY: the database stays as it is (expand/contract discipline
# is what makes the previous version safe against the current schema). The
# data plane (pg_restore) is a separate, destructive, human-confirmed act —
# see /forja:rollback.
#
# Usage: rollback-to.sh <production|preview> <tag|latest>
#   latest = the most recent <env>-<utc-ts> rollback tag on the node
#            (i.e. the last version that deployed HEALTHY — use it to undo
#            a rollback).
#
# Env: HEALTH_TIMEOUT  seconds for the node-side health window (default 90)
#
# Steps ([FAIL] + exit != 0 on any):
#   1. resolve the tag (and check the image exists on the node)
#   2. docker service update --image <app>:<tag> ${STACK}_app
#   3. wait for the service update state to reach 'completed'
#   4. node-side health probe; prints the running buildSha
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "${FORJA_ROOT}"

usage() {
  printf 'Usage: rollback-to.sh <production|preview> <tag|latest>\n' >&2
  exit 2
}
[ -n "${1:-}" ] && [ -n "${2:-}" ] || usage
env_ctx "$1"
target="$2"

# ── 1. Resolve the target tag ────────────────────────────────────────────────
if [ "${target}" = "latest" ]; then
  target="$(dk image ls --format '{{.Tag}}' "${APP}" 2>/dev/null \
    | grep -E "^${TAG_PREFIX}-" | sort -r | head -n 1 || true)"
  [ -n "${target}" ] \
    || fail "no ${TAG_PREFIX}-* rollback tags on the ${ENV_NAME} node — they are created after the first HEALTHY deploy (versions.sh ${ENV_NAME} to inspect)"
  log "latest resolves to ${target}"
fi

dk image inspect "${APP}:${target}" >/dev/null 2>&1 \
  || fail "image ${APP}:${target} not found on the ${ENV_NAME} node — run: bash scripts/release/versions.sh ${ENV_NAME}"

# ── 2. Re-point the service ──────────────────────────────────────────────────
log "re-pointing ${STACK}_app -> ${APP}:${target}"
dk service update --image "${APP}:${target}" "${STACK}_app" \
  || fail "service update failed or was rolled back by the swarm — inspect: docker service ps ${STACK}_app"

# ── 3. Wait for the update state ─────────────────────────────────────────────
deadline=$(( $(date +%s) + 180 ))
update_state=""
while :; do
  update_state="$(dk service inspect \
    --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' \
    "${STACK}_app" 2>/dev/null || true)"
  case "${update_state}" in
    completed|'')
      break
      ;;
    paused|rollback_started|rollback_paused|rollback_completed)
      fail "service update ended in state '${update_state}' — the swarm rejected this version (it did not pass the healthcheck)"
      ;;
    *) : ;;  # updating — keep waiting
  esac
  [ "$(date +%s)" -lt "${deadline}" ] \
    || fail "service update did not complete within 180s (state: ${update_state:-unknown})"
  sleep 5
done
pass "service update completed (${APP}:${target})"

# ── 4. Health + running buildSha ─────────────────────────────────────────────
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
if body="$(wait_node_health "${HEALTH_TIMEOUT}")"; then
  sha="$(json_field "${body}" buildSha)"
  desc=""
  if [ -n "${sha}" ] && [ "${sha}" != "dev" ] && git cat-file -e "${sha}^{commit}" 2>/dev/null; then
    desc=" — $(git log -1 --format='%h %s' "${sha}")"
  fi
  pass "rollback healthy: ${STACK}_app runs ${APP}:${target} (buildSha ${sha:-unknown}${desc})"
  log "remember: the next deploy supersedes any rollback — this is a bridge, not a destination"
else
  fail "service did not turn healthy within ${HEALTH_TIMEOUT}s after the rollback — inspect: docker service ps ${STACK}_app"
fi
