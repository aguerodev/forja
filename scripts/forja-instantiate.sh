#!/usr/bin/env bash
# forja-instantiate.sh - deterministic project instantiator for the forja plugin.
#
# Copies the project template tree, copies the infra sources into ops/, replaces
# {{TOKEN}} placeholders and enforces a zero-leftover-token gate. No prompts,
# no network: /forja:init gathers the answers and calls this with KEY=VALUE args.
#
# Usage:
#   forja-instantiate.sh <target-dir> KEY=VALUE...
#
# Required keys:
#   APP PUBLIC_NAME DOMAIN GH_ORG GH_REPO PG_MAJOR DB_USER DB_NAME PROJECT_NAME
#   CMD_INSTALL CMD_CHECK CMD_TEST CMD_VERSION APP_PORT HEALTH_PATH
# Optional keys:
#   FORJA_MARKETPLACE_REPO (default: aguerodev/forja)
#
# Environment:
#   FORCE=1                overwrite a non-empty target directory
#   FORJA_TEMPLATES_DIR    override the template tree (used by tests until the
#                          templates land; default: <plugin>/templates/project)
set -euo pipefail

die()  { printf 'forja-instantiate: ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'forja-instantiate: WARN: %s\n' "$*" >&2; }

usage() {
  printf 'Usage: forja-instantiate.sh <target-dir> KEY=VALUE...\n' >&2
  printf 'Required keys: APP PUBLIC_NAME DOMAIN GH_ORG GH_REPO PG_MAJOR DB_USER DB_NAME PROJECT_NAME CMD_INSTALL CMD_CHECK CMD_TEST CMD_VERSION APP_PORT HEALTH_PATH\n' >&2
  exit 2
}

command -v perl >/dev/null 2>&1 || die "perl is required for token replacement"
command -v node >/dev/null 2>&1 || die "node is required for the JSON output gate"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATES_DIR="${FORJA_TEMPLATES_DIR:-${PLUGIN_ROOT}/templates/project}"

[ "$#" -ge 1 ] || usage
TARGET="$1"
shift

# ── Parse KEY=VALUE arguments ────────────────────────────────────────────────
APP="" PUBLIC_NAME="" DOMAIN="" GH_ORG="" GH_REPO=""
PG_MAJOR="" DB_USER="" DB_NAME="" PROJECT_NAME=""
CMD_INSTALL="" CMD_CHECK="" CMD_TEST="" CMD_VERSION="" APP_PORT="" HEALTH_PATH=""
FORJA_MARKETPLACE_REPO="${FORJA_MARKETPLACE_REPO:-aguerodev/forja}"

for kv in "$@"; do
  case "${kv}" in
    *=*) ;;
    *) die "argument is not KEY=VALUE: ${kv}" ;;
  esac
  key="${kv%%=*}"
  value="${kv#*=}"
  case "${key}" in
    APP|PUBLIC_NAME|DOMAIN|GH_ORG|GH_REPO|PG_MAJOR|DB_USER|DB_NAME|PROJECT_NAME|CMD_INSTALL|CMD_CHECK|CMD_TEST|CMD_VERSION|APP_PORT|HEALTH_PATH|FORJA_MARKETPLACE_REPO)
      printf -v "${key}" '%s' "${value}" ;;
    *) die "unknown key: ${key}" ;;
  esac
done

for k in APP PUBLIC_NAME DOMAIN GH_ORG GH_REPO PG_MAJOR DB_USER DB_NAME PROJECT_NAME CMD_INSTALL CMD_CHECK CMD_TEST CMD_VERSION APP_PORT HEALTH_PATH; do
  [ -n "${!k}" ] || die "missing required key: ${k}"
done

# APP is the internal slug (snake_case); PUBLIC_NAME is a DNS label (no underscores).
[[ "${APP}" =~ ^[a-z][a-z0-9_]*$ ]] || die "invalid APP slug '${APP}' (expected: [a-z][a-z0-9_]*)"
[[ "${PUBLIC_NAME}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "invalid PUBLIC_NAME '${PUBLIC_NAME}' (DNS label: lowercase alphanumerics and hyphens, no underscores)"
# APP_PORT lands unquoted in .forja.json (runtime.port) and in probe URLs;
# HEALTH_PATH lands in URLs — both are validated for shape here (no spaces,
# no quotes, no shell metacharacters).
[[ "${APP_PORT}" =~ ^[0-9]+$ ]] || die "invalid APP_PORT '${APP_PORT}' (expected a number)"
[[ "${HEALTH_PATH}" =~ ^/[A-Za-z0-9/._-]*$ ]] || die "invalid HEALTH_PATH '${HEALTH_PATH}' (expected: / followed by [A-Za-z0-9/._-], no spaces or quotes)"
[[ "${PG_MAJOR}" =~ ^[0-9]+$ ]] || die "invalid PG_MAJOR '${PG_MAJOR}' (expected a number)"

[ -d "${TEMPLATES_DIR}" ] || die "templates directory not found: ${TEMPLATES_DIR} (set FORJA_TEMPLATES_DIR or ship templates/project)"

# ── Target directory checks ──────────────────────────────────────────────────
PARENT="$(dirname "${TARGET}")"
[ -d "${PARENT}" ] || die "parent directory does not exist: ${PARENT}"

if [ -e "${TARGET}" ]; then
  [ -d "${TARGET}" ] || die "target exists and is not a directory: ${TARGET}"
  EXTRAS="$(find "${TARGET}" -mindepth 1 -maxdepth 1 ! -name '.git' ! -name '.DS_Store' -print 2>/dev/null || true)"
  if [ -n "${EXTRAS}" ] && [ "${FORCE:-0}" != "1" ]; then
    printf 'forja-instantiate: target directory is not empty (only .git and .DS_Store are tolerated).\n' >&2
    printf 'forja-instantiate: found:\n%s\n' "${EXTRAS}" >&2
    die "refusing to overwrite (re-run with FORCE=1 to override)"
  fi
else
  mkdir -p "${TARGET}"
fi
TARGET="$(cd "${TARGET}" && pwd)"

# ── 1. Copy the template tree ────────────────────────────────────────────────
cp -R "${TEMPLATES_DIR}/." "${TARGET}"

# Ship env.example as a dotfile (the template tree cannot carry .env* names).
if [ -f "${TARGET}/env.example" ]; then
  mv "${TARGET}/env.example" "${TARGET}/.env.example"
fi

# Ship the secrets dir from its neutral template name (agent permission
# guards deny template paths under secrets/). Merge, never delete: on a
# FORCE=1 re-run an existing secrets/ may hold real gitignored *.env values.
if [ -d "${TARGET}/secrets.skel" ]; then
  mkdir -p "${TARGET}/secrets"
  cp -R "${TARGET}/secrets.skel/." "${TARGET}/secrets/"
  rm -rf "${TARGET}/secrets.skel"
fi

# ── 2. Copy the infra sources into ops/ ──────────────────────────────────────
mkdir -p "${TARGET}/ops"
for f in provision.sh verify.sh user_data.yaml firewall-rules.json; do
  src="${PLUGIN_ROOT}/wiki/operaciones/${f}"
  if [ -f "${src}" ]; then
    cp "${src}" "${TARGET}/ops/${f}"
  else
    warn "infra source missing, skipped: ${src}"
  fi
done

# ── 3. Replace {{TOKEN}} placeholders ────────────────────────────────────────
# Only tokens shaped {{[A-Z_]+}} whose key is known are replaced; anything else
# is left untouched for the leftover gate below. GitHub Actions forms like
# `${{ secrets.X }}` never match (the char right after `{{` is a space).
TOKEN_KEYS="APP PUBLIC_NAME DOMAIN GH_ORG GH_REPO PG_MAJOR DB_USER DB_NAME PROJECT_NAME CMD_INSTALL CMD_CHECK CMD_TEST CMD_VERSION APP_PORT HEALTH_PATH FORJA_MARKETPLACE_REPO"
for k in ${TOKEN_KEYS}; do
  export "FORJA_TOKEN_${k}=${!k}"
done

FILES_WITH_TOKENS="$(grep -RIl --exclude-dir=.git -E '\{\{[A-Z_]+\}\}' "${TARGET}" 2>/dev/null || true)"
if [ -n "${FILES_WITH_TOKENS}" ]; then
  while IFS= read -r f; do
    case "${f}" in
      *.json)
        # JSON-aware substitution: the same token can feed JSON and prose
        # (e.g. CMD_VERSION carries inner double quotes). Inside *.json the
        # value is escaped for a JSON string context; prose gets it raw.
        perl -pi -e 's/\{\{([A-Z_]+)\}\}/exists $ENV{"FORJA_TOKEN_$1"} ? do { my $v = $ENV{"FORJA_TOKEN_$1"}; $v =~ s{\\}{\\\\}g; $v =~ s{"}{\\"}g; $v =~ s{\n}{\\n}g; $v =~ s{\r}{\\r}g; $v =~ s{\t}{\\t}g; $v } : $&/ge' "${f}"
        ;;
      *)
        perl -pi -e 's/\{\{([A-Z_]+)\}\}/exists $ENV{"FORJA_TOKEN_$1"} ? $ENV{"FORJA_TOKEN_$1"} : $&/ge' "${f}"
        ;;
    esac
  done <<< "${FILES_WITH_TOKENS}"
fi

# ── 4. Executable bits ───────────────────────────────────────────────────────
find "${TARGET}" -type f -name '*.sh' -exec chmod +x {} +

# ── 5. Leftover-token gate ───────────────────────────────────────────────────
# The regex deliberately does NOT match `${{ secrets.x }}` (space after `{{`).
LEFTOVER="$(grep -RInE --exclude-dir=.git '\{\{[A-Z_]+\}\}' "${TARGET}" 2>/dev/null || true)"
if [ -n "${LEFTOVER}" ]; then
  printf 'forja-instantiate: ERROR: unreplaced tokens remain:\n%s\n' "${LEFTOVER}" >&2
  exit 1
fi

# ── 6. JSON output gate ──────────────────────────────────────────────────────
# Every *.json in the output tree must parse: a token value that broke a JSON
# file (despite the escaping above) fails the run here, never silently.
JSON_FILES="$(find "${TARGET}" -type f -name '*.json' -not -path '*/.git/*' 2>/dev/null || true)"
if [ -n "${JSON_FILES}" ]; then
  while IFS= read -r jf; do
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "${jf}" >/dev/null 2>&1 \
      || die "[FAIL] invalid JSON after token substitution: ${jf}"
  done <<< "${JSON_FILES}"
fi

printf 'forja-instantiate: OK - project instantiated at %s (app=%s, public=%s.%s)\n' \
  "${TARGET}" "${APP}" "${PUBLIC_NAME}" "${DOMAIN}"
