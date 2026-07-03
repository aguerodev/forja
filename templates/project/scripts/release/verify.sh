#!/usr/bin/env bash
# scripts/release/verify.sh — deployed SHA == expected + smoke (ops/08).
# "The deploy served SOMETHING" is not verification; this script proves it
# serves the exact commit the operator released.
#
# Usage: verify.sh [production|preview]
#   Without an argument: production — UNLESS STACK/PUBLIC_HOST are preset to
#   the test stack (the /forja:deploy preview flow runs
#   `STACK=<app>_test PUBLIC_HOST=<dev>-... verify.sh`), which selects preview
#   so the docker context stays LOCAL.
#
# Env:
#   EXPECTED_SHA   commit the deploy should serve (default: local git HEAD)
#   STACK          override the stack name  (wins over env_ctx)
#   PUBLIC_HOST    override the public host (wins over env_ctx)
#
# Checks, each [PASS]/[FAIL]; exit code = number of failures:
#   1. deployed buildSha matches EXPECTED_SHA (prefix compare). The edge is
#      probed first (with retries — it can lag through the tunnel); if it is
#      down or disagrees, the node-side exec is the AUTHORITATIVE fallback:
#      /api/health ships Cache-Control: no-store, and the container answer
#      cannot be faked by any cache.
#   2. smoke: /            -> 200
#   3. smoke: /api/health  -> 200
#   4. smoke: bogus path   -> 404
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_cmd git curl
cd "${FORJA_ROOT}"

STACK_OVERRIDE="${STACK:-}"
HOST_OVERRIDE="${PUBLIC_HOST:-}"

env_arg="${1:-}"
if [ -z "${env_arg}" ]; then
  if [ -n "${STACK_OVERRIDE}" ] && [ "${STACK_OVERRIDE}" = "${APP}_test" ]; then
    env_arg="preview"
  else
    env_arg="production"
  fi
fi
env_ctx "${env_arg}"
if [ -n "${STACK_OVERRIDE}" ]; then STACK="${STACK_OVERRIDE}"; fi
if [ -n "${HOST_OVERRIDE}" ]; then PUBLIC_HOST="${HOST_OVERRIDE}"; fi

EXPECTED_SHA="${EXPECTED_SHA:-$(git rev-parse HEAD)}"
FAILURES=0

log "verifying ${STACK} at https://${PUBLIC_HOST} against ${EXPECTED_SHA}"

# One is a non-empty prefix of the other (full sha vs short sha tolerant).
sha_match() {
  [ -n "${1}" ] && [ -n "${2}" ] || return 1
  case "${1}" in "${2}"*) return 0 ;; esac
  case "${2}" in "${1}"*) return 0 ;; esac
  return 1
}

# ── Check 1: deployed buildSha ───────────────────────────────────────────────
deployed_sha=""
sha_source=""
for _try in 1 2 3; do
  body="$(curl -fsS -m 10 "https://${PUBLIC_HOST}/api/health" 2>/dev/null || true)"
  candidate="$(json_field "${body}" buildSha)"
  if [ -n "${candidate}" ]; then
    deployed_sha="${candidate}"
    sha_source="edge"
    break
  fi
  sleep 5
done

if ! sha_match "${deployed_sha}" "${EXPECTED_SHA}"; then
  # Edge down or disagreeing — ask the container itself (authoritative).
  body="$(node_health || true)"   # 503 still carries buildSha
  candidate="$(json_field "${body}" buildSha)"
  if [ -n "${candidate}" ]; then
    deployed_sha="${candidate}"
    sha_source="node-side (authoritative)"
  fi
fi

if [ -z "${deployed_sha}" ]; then
  fail_line "could not read the deployed buildSha (edge unreachable AND no answer from the ${STACK}_app container)"
  FAILURES=$((FAILURES + 1))
elif sha_match "${deployed_sha}" "${EXPECTED_SHA}"; then
  pass "deployed buildSha ${deployed_sha} matches expected (via ${sha_source})"
else
  fail_line "deployed buildSha ${deployed_sha} != expected ${EXPECTED_SHA} (via ${sha_source}) — the deploy served something else"
  FAILURES=$((FAILURES + 1))
fi

# ── Checks 2-4: smoke over the edge ──────────────────────────────────────────
smoke() { # $1 path, $2 expected http code
  local code=""
  local _try
  for _try in 1 2 3; do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://${PUBLIC_HOST}$1" || true)"
    if [ "${code}" = "$2" ]; then
      pass "smoke $1 -> $2"
      return 0
    fi
    sleep 3
  done
  fail_line "smoke $1 -> expected $2, got ${code:-000}"
  FAILURES=$((FAILURES + 1))
}

smoke "/" 200
smoke "/api/health" 200
smoke "/forja-smoke-bogus-$(date +%s)" 404

exit "${FAILURES}"
