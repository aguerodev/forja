# shellcheck shell=bash
# scripts/release/lib.sh — shared context for the release scripts.
# (doctrine: wiki ops/06 + ops/08 — load `forja:doctrina`, recipe `desplegar`)
#
# SOURCED, never executed. deploy.sh (repo root) and every script under
# scripts/release/ start with:  source "<repo>/scripts/release/lib.sh"
#
# Provides:
#   - Project context read from .forja.json at the repo root (parsed with
#     node, which is always present in this stack). Exports:
#       APP PUBLIC_NAME DOMAIN DB_USER DB_NAME DOCKER_CONTEXT_PROD
#   - env_ctx production|preview   (aliases: prod, test)
#       production -> STACK=<app>_prod   PUBLIC_HOST=<publicName>.<domain>
#                     export DOCKER_CONTEXT=<dockerContext from .forja.json>
#       preview    -> STACK=<app>_test   PUBLIC_HOST=dev-<publicName>.<domain>
#                     unset DOCKER_CONTEXT (an inherited context must NEVER
#                     redirect a test deploy to the production node)
#       Also exports ENV_NAME (production|preview) and TAG_PREFIX (prod|test),
#       the rollback-image tag namespace shared by deploy.sh, versions.sh and
#       rollback-to.sh.
#   - dk: docker wrapper that applies the resolved context explicitly.
#   - REQUIRED_SECRETS: the 7 runtime secrets asserted before any migration
#     (names match stack.yml and secrets/README.md).
#   - Helpers: log warn pass fail_line fail, utc_ts, require_cmd, pkg_version,
#     service_container_id, node_health, wait_node_health, json_field.
#
# Bash 3.2 compatible on purpose: these scripts run on the operator machine
# (macOS ships bash 3.2) as well as on Linux. No mapfile, no assoc arrays.

# Guard: this file is a library.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf '[FAIL] lib.sh is a library: source it, do not execute it\n' >&2
  exit 1
fi

# ── Logging / result helpers ─────────────────────────────────────────────────
log()       { printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
warn()      { printf '[WARN] %s\n' "$*" >&2; }
pass()      { printf '[PASS] %s\n' "$*"; }
fail_line() { printf '[FAIL] %s\n' "$*" >&2; }   # print, do NOT exit (gate scripts count failures)
fail()      { fail_line "$*"; exit 1; }          # print and abort

utc_ts() { date -u '+%Y%m%d-%H%M%S'; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || fail "required command not found: $c"
  done
}

require_cmd node

# ── Project context from .forja.json ─────────────────────────────────────────
FORJA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORJA_JSON="${FORJA_ROOT}/.forja.json"

[ -f "${FORJA_JSON}" ] || fail ".forja.json not found at ${FORJA_ROOT} — run /forja:init (or create it at the repo root) before using the release scripts"

# One node call validates the file and emits KEY=VALUE lines. Values feed
# shell variables, so anything outside a conservative charset is rejected.
_forja_ctx="$(node -e '
const fs = require("fs");
let cfg;
try {
  cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
} catch (err) {
  console.error("invalid JSON: " + err.message);
  process.exit(1);
}
const fields = {
  APP: cfg.app,
  PUBLIC_NAME: cfg.publicName,
  DOMAIN: cfg.domain,
  DOCKER_CONTEXT_PROD: cfg.dockerContext,
  DB_USER: cfg.db && cfg.db.user,
  DB_NAME: cfg.db && cfg.db.name,
};
const missing = Object.keys(fields).filter(
  (k) => fields[k] == null || String(fields[k]).trim() === "",
);
if (missing.length > 0) {
  console.error("missing fields: " + missing.join(", "));
  process.exit(1);
}
for (const key of Object.keys(fields)) {
  const value = String(fields[key]);
  if (!/^[A-Za-z0-9._-]+$/.test(value)) {
    console.error("field " + key + " contains unsupported characters: " + value);
    process.exit(1);
  }
  console.log(key + "=" + value);
}
' "${FORJA_JSON}" 2>&1)" || fail ".forja.json is invalid (${FORJA_JSON}): ${_forja_ctx}"

while IFS='=' read -r _k _v; do
  case "${_k}" in
    APP|PUBLIC_NAME|DOMAIN|DOCKER_CONTEXT_PROD|DB_USER|DB_NAME)
      printf -v "${_k}" '%s' "${_v}"
      export "${_k?}"
      ;;
  esac
done <<EOF_FORJA_CTX
${_forja_ctx}
EOF_FORJA_CTX
unset _k _v _forja_ctx

# The 7 runtime secrets deploy.sh materializes and asserts (as ${STACK}_<key>)
# BEFORE touching the database. Single source of truth for scripts; the
# authoritative contract lives in stack.yml + secrets/README.md.
REQUIRED_SECRETS="db_url session_secret app_base_url db_password tunnel_token storage_box_dest backup_ssh_key_b64"
export REQUIRED_SECRETS

# ── Environment resolution ───────────────────────────────────────────────────
env_ctx() {
  case "${1:-}" in
    production|prod)
      ENV_NAME="production"
      STACK="${APP}_prod"
      PUBLIC_HOST="${PUBLIC_NAME}.${DOMAIN}"
      TAG_PREFIX="prod"
      export DOCKER_CONTEXT="${DOCKER_CONTEXT_PROD}"
      ;;
    preview|test)
      ENV_NAME="preview"
      STACK="${APP}_test"
      # Per-developer preview host: <dev>-<publicName>.<domain>. The label
      # comes from `git config forja.devUser` (set by /forja:init from the
      # gh login); "dev" is the single-developer fallback. Each dev runs
      # their own local Swarm + tunnel, so hostnames must not collide.
      _dev_label="$(git config --get forja.devUser 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
      PUBLIC_HOST="${_dev_label:-dev}-${PUBLIC_NAME}.${DOMAIN}"
      unset _dev_label
      TAG_PREFIX="test"
      # Deliberate: a context inherited from the caller must never send a
      # test deploy to the production node. Local engine, always.
      unset DOCKER_CONTEXT
      ;;
    *)
      fail "env_ctx: unknown environment '${1:-}' (expected: production|preview)"
      ;;
  esac
  export ENV_NAME STACK PUBLIC_HOST TAG_PREFIX
}

# docker on the environment's engine. The context travels as an explicit flag
# (not just the env var) so every call site is unambiguous.
dk() {
  require_cmd docker
  if [ -n "${DOCKER_CONTEXT:-}" ]; then
    docker --context "${DOCKER_CONTEXT}" "$@"
  else
    docker "$@"
  fi
}

# ── Stack helpers ────────────────────────────────────────────────────────────

# Newest running container of a stack service on the env's engine.
# Prints the id, or NOTHING when absent/unreachable (callers poll or fail on
# empty — a transient engine error must not blow up a retry loop under -e).
# Usage: service_container_id <service-suffix>   (app | db | backup | ...)
service_container_id() {
  dk ps --filter "label=com.docker.swarm.service.name=${STACK}_$1" \
    --format '{{.ID}}' 2>/dev/null | head -n 1 || true
}

# Node-side health probe — the AUTHORITATIVE signal (doctrine ops/06 phase 5):
# exec into the app task and fetch /api/health on localhost. Prints the JSON
# body (also for a 503 — it still carries buildSha); exit 0 only on HTTP 200.
node_health() {
  local cid
  cid="$(service_container_id app)"
  [ -n "${cid}" ] || return 1
  dk exec "${cid}" node -e '
fetch("http://127.0.0.1:8000/api/health")
  .then(async (r) => {
    process.stdout.write(await r.text());
    process.exit(r.ok ? 0 : 1);
  })
  .catch(() => process.exit(1));
' 2>/dev/null
}

# Poll node_health until HTTP 200 or timeout. Prints the healthy body.
# Usage: wait_node_health [timeout-seconds]   (default 90)
wait_node_health() {
  local timeout deadline body
  timeout="${1:-90}"
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    if body="$(node_health)"; then
      printf '%s' "${body}"
      return 0
    fi
    [ "$(date +%s)" -lt "${deadline}" ] || return 1
    sleep 5
  done
}

# json_field '<json>' <field> — prints the field value, or nothing if the
# input is not JSON / the field is absent. node does the parsing (no jq dep).
json_field() {
  printf '%s' "$1" | node -e '
try {
  const parsed = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const value = parsed[process.argv[1]];
  if (value != null) process.stdout.write(String(value));
} catch {
  /* not JSON: print nothing */
}
' "$2"
}

# Version from package.json — the single version datum of the project.
pkg_version() {
  node -p 'require(process.argv[1] + "/package.json").version' "${FORJA_ROOT}" 2>/dev/null \
    || fail "cannot read .version from ${FORJA_ROOT}/package.json"
}
