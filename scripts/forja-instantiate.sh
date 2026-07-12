#!/usr/bin/env bash
# forja-instantiate.sh - deterministic project instantiator for the forja plugin.
#
# Installs the agnostic forja layer (contract, release scripts, ops sources,
# team settings), replaces {{TOKEN}} placeholders in the files IT wrote and
# enforces zero-leftover-token and valid-JSON gates over those files. No
# prompts, no network: /forja:init gathers the answers and calls this with
# KEY=VALUE args.
#
# Modes:
#   new   (default)  target must be empty (only .git/.DS_Store tolerated).
#                    FORCE=1 allows a non-empty target and OVERWRITES existing
#                    files (explicit destructive re-stamp) — except .forja.json,
#                    which is never overwritten by anyone.
#   adopt (ADOPT=1)  target is an existing project. NEVER overwrites: an
#                    existing file (or symlink, even broken) is skipped and
#                    reported as a collision at the end (exit 0). Exception:
#                    an existing .forja.json is a hard fail — the project is
#                    already initialized. ADOPT=1 + FORCE=1 is rejected.
#
# Safety invariants:
#   - Pre-scan before any write: every destination directory component must be
#     a real directory (no symlinks, no regular files in the way) — blockers
#     abort the run up-front, so a failing run never leaves a half-adopted repo.
#   - Collision checks use -e OR -L: a broken symlink at a destination counts
#     as existing (nothing is ever written THROUGH a symlink).
#   - .forja.json is written LAST, as the commit marker: an interrupted run
#     never looks initialized.
#   - The run ends printing one `installed: <path>` line per file written, so
#     the caller can stage exactly those paths (never directory globs).
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
#   ADOPT=1                adopt mode (see above)
#   FORCE=1                new mode only: overwrite a non-empty target
#   FORJA_TEMPLATES_DIR    override the template tree (used by tests;
#                          default: <plugin>/templates/project)
set -euo pipefail

die()  { printf 'forja-instantiate: ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'forja-instantiate: WARN: %s\n' "$*" >&2; }

usage() {
  printf 'Usage: forja-instantiate.sh <target-dir> KEY=VALUE...\n' >&2
  printf 'Required keys: APP PUBLIC_NAME DOMAIN GH_ORG GH_REPO PG_MAJOR DB_USER DB_NAME PROJECT_NAME CMD_INSTALL CMD_CHECK CMD_TEST CMD_VERSION APP_PORT HEALTH_PATH\n' >&2
  printf 'Modes: default requires an empty target; ADOPT=1 installs onto an existing project without overwriting.\n' >&2
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

# ── Mode + target directory checks ───────────────────────────────────────────
ADOPT="${ADOPT:-0}"
FORCE="${FORCE:-0}"
if [ "${ADOPT}" = "1" ] && [ "${FORCE}" = "1" ]; then
  die "ADOPT=1 and FORCE=1 are contradictory: adopt never overwrites project files"
fi

PARENT="$(dirname "${TARGET}")"
[ -d "${PARENT}" ] || die "parent directory does not exist: ${PARENT}"

if [ "${ADOPT}" = "1" ]; then
  [ -d "${TARGET}" ] || die "adopt mode requires an existing project directory: ${TARGET}"
  if [ -e "${TARGET}/.forja.json" ] || [ -L "${TARGET}/.forja.json" ]; then
    die ".forja.json already exists — the project is already initialized (check it with /forja:doctor; forja never overwrites the contract)"
  fi
else
  if [ -e "${TARGET}" ]; then
    [ -d "${TARGET}" ] || die "target exists and is not a directory: ${TARGET}"
    # The contract is never overwritten — not even under FORCE=1.
    if [ -e "${TARGET}/.forja.json" ] || [ -L "${TARGET}/.forja.json" ]; then
      die ".forja.json already exists — the project is already initialized (check it with /forja:doctor; forja never overwrites the contract, FORCE included)"
    fi
    EXTRAS="$(find "${TARGET}" -mindepth 1 -maxdepth 1 ! -name '.git' ! -name '.DS_Store' -print 2>/dev/null || true)"
    if [ -n "${EXTRAS}" ] && [ "${FORCE}" != "1" ]; then
      printf 'forja-instantiate: target directory is not empty (only .git and .DS_Store are tolerated).\n' >&2
      printf 'forja-instantiate: found:\n%s\n' "${EXTRAS}" >&2
      die "refusing to overwrite (adopt the project with ADOPT=1, or re-run with FORCE=1 to overwrite)"
    fi
  else
    mkdir -p "${TARGET}"
  fi
fi
TARGET="$(cd "${TARGET}" && pwd)"

# ── 1. Build the install plan ────────────────────────────────────────────────
# PLAN lines: "<source-abs>\t<dest-rel>". Nothing is written in this phase.
# Two renames on the way in:
#   env.example      -> .env.example  (the template tree cannot carry .env* names)
#   secrets.skel/... -> secrets/...   (agent permission guards deny template
#                                      paths under secrets/; merge, never delete)
PLAN=""
FORJA_JSON_SRC=""

while IFS= read -r rel; do
  case "${rel}" in
    env.example)     destrel=".env.example" ;;
    secrets.skel/*)  destrel="secrets/${rel#secrets.skel/}" ;;
    *)               destrel="${rel}" ;;
  esac
  if [ "${destrel}" = ".forja.json" ]; then
    # The contract is written LAST (commit marker): an interrupted run never
    # looks initialized. It is kept out of the main plan on purpose.
    FORJA_JSON_SRC="${TEMPLATES_DIR}/${rel}"
    continue
  fi
  PLAN="${PLAN}${TEMPLATES_DIR}/${rel}"$'\t'"${destrel}"$'\n'
done < <(cd "${TEMPLATES_DIR}" && find . -type f ! -name '.DS_Store' | sed 's|^\./||' | sort)

for f in provision.sh verify.sh user_data.yaml firewall-rules.json; do
  src="${PLUGIN_ROOT}/wiki/operaciones/${f}"
  if [ -f "${src}" ]; then
    PLAN="${PLAN}${src}"$'\t'"ops/${f}"$'\n'
  else
    warn "infra source missing, skipped: ${src}"
  fi
done

# ── 2. Pre-scan destination directories (before ANY write) ───────────────────
# Every directory component of every destination must be either absent or a
# REAL directory: a symlinked component would let the install escape the repo
# (writes would land wherever the link points), and a regular file in the way
# would kill mkdir -p mid-run leaving a half-adopted repo. Both abort here,
# up-front, with the full blocker list — before anything is written.
check_dest_dir() { # $1 = dest dir relative to TARGET ("." = nothing to check)
  local rel="$1" cur="${TARGET}" seg rest
  if [ "${rel}" = "." ]; then return 0; fi
  rest="${rel}"
  while [ -n "${rest}" ]; do
    seg="${rest%%/*}"
    if [ "${seg}" = "${rest}" ]; then rest=""; else rest="${rest#*/}"; fi
    cur="${cur}/${seg}"
    if [ -L "${cur}" ]; then
      printf '%s (symlink — forja never writes through symlinks)\n' "${cur#"${TARGET}"/}"
      return 0
    fi
    if [ -e "${cur}" ] && [ ! -d "${cur}" ]; then
      printf '%s (exists and is not a directory)\n' "${cur#"${TARGET}"/}"
      return 0
    fi
    if [ ! -e "${cur}" ]; then return 0; fi # nothing deeper can exist
  done
  return 0
}

BLOCKERS=""
while IFS=$'\t' read -r src destrel; do
  if [ -z "${destrel:-}" ]; then continue; fi
  HIT="$(check_dest_dir "$(dirname "${destrel}")")"
  if [ -n "${HIT}" ]; then
    BLOCKERS="${BLOCKERS}${HIT}"$'\n'
  fi
done <<< "${PLAN}"
if [ -n "${BLOCKERS}" ]; then
  printf 'forja-instantiate: ERROR: destination paths are blocked (nothing was written):\n' >&2
  printf '%s' "${BLOCKERS}" | sort -u | sed 's/^/  - /' >&2
  exit 1
fi

# ── 3. Install the layer (per-file; adopt never clobbers) ────────────────────
# WRITTEN tracks the files THIS RUN wrote: substitution and the output gates
# below operate ONLY on them — the project's own files are never touched.
WRITTEN=""
COLLISIONS=""

install_file() { # $1 = source (absolute), $2 = destination (relative to TARGET)
  local dest="${TARGET}/$2"
  # -e OR -L: a BROKEN symlink fails -e but must still count as a collision —
  # cp would write THROUGH it, creating the link's target (possibly outside
  # the repo), and the written-through file would escape the gates.
  if [ -e "${dest}" ] || [ -L "${dest}" ]; then
    if [ "${ADOPT}" = "1" ]; then
      COLLISIONS="${COLLISIONS}$2"$'\n'
      return 0
    fi
    if [ "${FORCE}" != "1" ]; then
      die "unexpected collision in new mode: $2"
    fi
    # FORCE=1 (new mode): explicit destructive re-stamp. Remove the entry
    # itself first (never write through a symlink), then copy fresh.
    rm -f "${dest}"
  fi
  mkdir -p "$(dirname "${dest}")"
  cp "$1" "${dest}"
  WRITTEN="${WRITTEN}${dest}"$'\n'
}

while IFS=$'\t' read -r src destrel; do
  if [ -z "${destrel:-}" ]; then continue; fi
  install_file "${src}" "${destrel}"
done <<< "${PLAN}"

# ── 4. Replace {{TOKEN}} placeholders (only in files this run wrote) ─────────
# Only tokens shaped {{[A-Z_]+}} whose key is known are replaced; anything else
# is left untouched for the leftover gate below. GitHub Actions forms like
# `${{ secrets.X }}` never match (the char right after `{{` is a space).
TOKEN_KEYS="APP PUBLIC_NAME DOMAIN GH_ORG GH_REPO PG_MAJOR DB_USER DB_NAME PROJECT_NAME CMD_INSTALL CMD_CHECK CMD_TEST CMD_VERSION APP_PORT HEALTH_PATH FORJA_MARKETPLACE_REPO"
for k in ${TOKEN_KEYS}; do
  export "FORJA_TOKEN_${k}=${!k}"
done

substitute_tokens() { # $1 = file (absolute)
  if ! grep -qIE '\{\{[A-Z_]+\}\}' "$1" 2>/dev/null; then return 0; fi
  case "$1" in
    *.json)
      # JSON-aware substitution: the same token can feed JSON and prose
      # (e.g. CMD_VERSION carries inner double quotes). Inside *.json the
      # value is escaped for a JSON string context; prose gets it raw.
      perl -pi -e 's/\{\{([A-Z_]+)\}\}/exists $ENV{"FORJA_TOKEN_$1"} ? do { my $v = $ENV{"FORJA_TOKEN_$1"}; $v =~ s{\\}{\\\\}g; $v =~ s{"}{\\"}g; $v =~ s{\n}{\\n}g; $v =~ s{\r}{\\r}g; $v =~ s{\t}{\\t}g; $v } : $&/ge' "$1"
      ;;
    *)
      perl -pi -e 's/\{\{([A-Z_]+)\}\}/exists $ENV{"FORJA_TOKEN_$1"} ? $ENV{"FORJA_TOKEN_$1"} : $&/ge' "$1"
      ;;
  esac
}

while IFS= read -r f; do
  if [ -z "${f}" ]; then continue; fi
  substitute_tokens "${f}"
done <<< "${WRITTEN}"

# ── 5. Executable bits (only on files this run wrote) ────────────────────────
while IFS= read -r f; do
  if [ -z "${f}" ]; then continue; fi
  case "${f}" in
    *.sh) chmod +x "${f}" ;;
  esac
done <<< "${WRITTEN}"

# ── 6. Leftover-token gate (only over files this run wrote) ──────────────────
# The regex deliberately does NOT match `${{ secrets.x }}` (space after `{{`).
gate_leftover() { # reads a file list on stdin; prints hits
  local f hits
  while IFS= read -r f; do
    if [ -z "${f}" ]; then continue; fi
    hits="$(grep -HnE '\{\{[A-Z_]+\}\}' "${f}" 2>/dev/null || true)"
    if [ -n "${hits}" ]; then printf '%s\n' "${hits}"; fi
  done
}
LEFTOVER="$(printf '%s' "${WRITTEN}" | gate_leftover)"
if [ -n "${LEFTOVER}" ]; then
  printf 'forja-instantiate: ERROR: unreplaced tokens remain:\n%s\n' "${LEFTOVER}" >&2
  exit 1
fi

# ── 7. JSON output gate (only over files this run wrote) ─────────────────────
# Every *.json this run wrote must parse: a token value that broke a JSON file
# (despite the escaping above) fails the run here, never silently. The
# project's own JSON files are out of scope on purpose.
gate_json() { # $1 = file (absolute)
  case "$1" in
    *.json)
      node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$1" >/dev/null 2>&1 \
        || die "[FAIL] invalid JSON after token substitution: $1"
      ;;
  esac
}
while IFS= read -r jf; do
  if [ -z "${jf}" ]; then continue; fi
  gate_json "${jf}"
done <<< "${WRITTEN}"

# ── 8. The contract, LAST (commit marker) ────────────────────────────────────
# Everything else is in place and gated; only now does the project start
# looking initialized. An interrupted run before this point leaves no
# .forja.json, so a clean re-run is possible.
if [ -n "${FORJA_JSON_SRC}" ]; then
  install_file "${FORJA_JSON_SRC}" ".forja.json"
  substitute_tokens "${TARGET}/.forja.json"
  LEFTOVER="$(printf '%s\n' "${TARGET}/.forja.json" | gate_leftover)"
  if [ -n "${LEFTOVER}" ]; then
    printf 'forja-instantiate: ERROR: unreplaced tokens remain:\n%s\n' "${LEFTOVER}" >&2
    exit 1
  fi
  gate_json "${TARGET}/.forja.json"
else
  warn "template has no .forja.json — no contract was written"
fi

# ── Result ───────────────────────────────────────────────────────────────────
if [ "${ADOPT}" = "1" ] && [ -n "${COLLISIONS}" ]; then
  printf 'forja-instantiate: kept existing files (NOT overwritten):\n'
  printf '%s' "${COLLISIONS}" | sed 's/^/  - /'
fi
# One line per written file: the caller stages EXACTLY these paths (never
# directory globs — an adopted repo has its own files in those directories).
printf 'forja-instantiate: installed files:\n'
while IFS= read -r f; do
  if [ -z "${f}" ]; then continue; fi
  printf '  installed: %s\n' "${f#"${TARGET}"/}"
done <<< "${WRITTEN}"
if [ "${ADOPT}" = "1" ]; then
  printf 'forja-instantiate: OK - project adopted at %s (app=%s, public=%s.%s)\n' \
    "${TARGET}" "${APP}" "${PUBLIC_NAME}" "${DOMAIN}"
else
  printf 'forja-instantiate: OK - project instantiated at %s (app=%s, public=%s.%s)\n' \
    "${TARGET}" "${APP}" "${PUBLIC_NAME}" "${DOMAIN}"
fi
