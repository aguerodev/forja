#!/usr/bin/env bash
# scripts/release/preflight.sh — the release provenance gate (production).
# (doctrine: wiki ops/08 — the preflight IS the provenance gate: with no
# branch protection on the free plan, "only main reaches prod" is an exit
# code here, not prose.)
#
# Gates, each printed as [PASS]/[FAIL]; exit code = number of failed gates:
#   1. current branch is main
#   2. working tree is clean
#   3. HEAD == origin/main — neither ahead nor behind (fetches origin main)
#   4. tag v<project version> is FREE (forces the version bump; the version
#      comes from the contract command, default package.json)
#   5. prod secrets soft-present: secrets/prod.env locally OR all required
#      secrets already bootstrapped in the prod swarm. SOFT half of the
#      control — the hard assert is deploy.sh's REQUIRED_SECRETS check
#      against the swarm before touching the database.
#   6. contract check command green (commands.check from .forja.json; default
#      `pnpm run check`). Skipped (not counted) when an earlier gate already
#      failed: the run takes minutes and the release is already blocked — fix
#      the cheap gate first.
#
# All green -> prints the release summary (version, HEAD, target host).
# The human confirmation ("prod") is NEVER scripted: /forja:deploy owns it.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_cmd git
# pnpm is only a hard requirement when the contract commands actually use it
# (the v1 default). A project on another toolchain brings its own commands.
case "${FORJA_CHECK_CMD} ${FORJA_VERSION_CMD}" in
  *pnpm*) require_cmd pnpm ;;
esac
cd "${FORJA_ROOT}"

env_ctx production

FAILURES=0
gate_fail() {
  fail_line "$1"
  FAILURES=$((FAILURES + 1))
}

# ── Gate 1: branch is main ───────────────────────────────────────────────────
branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "${branch}" = "main" ]; then
  pass "branch is main"
else
  gate_fail "branch is '${branch}' — production releases run ONLY from main"
fi

# ── Gate 2: clean working tree ───────────────────────────────────────────────
if [ -z "$(git status --porcelain)" ]; then
  pass "working tree is clean"
else
  gate_fail "working tree is dirty — commit or stash before releasing"
fi

# ── Gate 3: HEAD == origin/main ──────────────────────────────────────────────
if git fetch --quiet origin main 2>/dev/null; then
  head_sha="$(git rev-parse HEAD)"
  origin_sha="$(git rev-parse origin/main 2>/dev/null || true)"
  if [ -n "${origin_sha}" ] && [ "${head_sha}" = "${origin_sha}" ]; then
    pass "HEAD == origin/main ($(git rev-parse --short HEAD))"
  else
    counts="$(git rev-list --left-right --count origin/main...HEAD 2>/dev/null || printf '? ?')"
    read -r behind ahead <<EOF_COUNTS
${counts}
EOF_COUNTS
    gate_fail "HEAD != origin/main (behind ${behind:-?}, ahead ${ahead:-?}) — sync with origin first"
  fi
else
  gate_fail "cannot fetch origin main — provenance against origin cannot be verified"
fi

# ── Gate 4: release tag is free ──────────────────────────────────────────────
version="$(project_version)"
tag="v${version}"
if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
  gate_fail "tag ${tag} already exists — bump the project version (the datum read by commands.version; default package.json) on a release/* branch before releasing"
else
  pass "tag ${tag} is free"
fi

# ── Gate 5: prod secrets soft-present ────────────────────────────────────────
if [ -f "secrets/prod.env" ]; then
  pass "prod secrets: secrets/prod.env present locally"
else
  if swarm_secrets="$(dk secret ls --format '{{.Name}}' 2>/dev/null)"; then
    missing=""
    for s in ${REQUIRED_SECRETS}; do
      printf '%s\n' "${swarm_secrets}" | grep -qx "${STACK}_${s}" || missing="${missing} ${s}"
    done
    if [ -z "${missing}" ]; then
      pass "prod secrets: all required secrets already bootstrapped in the swarm"
    else
      gate_fail "prod secrets: no secrets/prod.env and missing in the swarm:${missing}"
    fi
  else
    gate_fail "prod secrets: no secrets/prod.env and the prod swarm is unreachable (context ${DOCKER_CONTEXT})"
  fi
fi

# ── Gate 6: contract check command (default: pnpm run check) ────────────────
if [ "${FAILURES}" -gt 0 ]; then
  printf '[SKIP] %s — %d gate(s) already failed, fix those first\n' "${FORJA_CHECK_CMD}" "${FAILURES}"
else
  if sh -c "${FORJA_CHECK_CMD}"; then
    pass "${FORJA_CHECK_CMD} green"
  else
    gate_fail "${FORJA_CHECK_CMD} failed — nothing ships red (fix the code, never the gate)"
  fi
fi

# ── Result ───────────────────────────────────────────────────────────────────
if [ "${FAILURES}" -eq 0 ]; then
  printf '\n── Release summary ──────────────────────────────────────────\n'
  printf '  version : %s (tag %s is free)\n' "${version}" "${tag}"
  printf '  HEAD    : %s\n' "$(git log -1 --format='%h %s')"
  printf '  target  : https://%s (stack %s via docker context %s)\n' \
    "${PUBLIC_HOST}" "${STACK}" "${DOCKER_CONTEXT}"
  printf '─────────────────────────────────────────────────────────────\n'
fi
exit "${FAILURES}"
