#!/usr/bin/env bash
# bash-guard.sh - PreToolUse(Bash) guard for the forja plugin.
#
# Enforces, ONLY inside forja projects (repo root contains .forja.json):
#   1. No raw `hcloud` CLI for the agent (must go through hcloud-agent.sh).
#   2. No `git push` to main/develop (Gitflow: PRs only).
#   3. No `git commit` while standing on main/develop (empty repo exempted,
#      so the bootstrap first commit of /forja:init works).
#   4. No AI attribution trailers in commit commands.
#
# Contract: stdin gets the hook payload JSON; a deny answers with
# permissionDecision JSON on stdout; an allow exits 0 with no output.
# Fail-open by design: any missing dependency or parse error must never
# block work (exit 0, silent).
set -u
set -f  # no pathname expansion while word-splitting command tokens

# Fail open if node (our JSON parser; no jq dependency) is unavailable.
command -v node >/dev/null 2>&1 || exit 0

PAYLOAD="$(cat 2>/dev/null || printf '')"
[ -n "${PAYLOAD}" ] || exit 0

json_field() {
  printf '%s' "${PAYLOAD}" | node -e '
    let d = "";
    process.stdin.on("data", (c) => (d += c));
    process.stdin.on("end", () => {
      try {
        let v = JSON.parse(d);
        for (const k of process.argv[1].split(".")) v = (v ?? {})[k];
        if (typeof v === "string") process.stdout.write(v);
      } catch {}
    });
  ' "$1" 2>/dev/null || printf ''
}

CMD="$(json_field tool_input.command)"
[ -n "${CMD}" ] || exit 0
CWD="$(json_field cwd)"
[ -n "${CWD}" ] || CWD="${PWD}"

ROOT="$(git -C "${CWD}" rev-parse --show-toplevel 2>/dev/null || printf '%s' "${CWD}")"

# Scope gate: all rules apply only inside forja projects.
[ -f "${ROOT}/.forja.json" ] || exit 0

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# Regexes (ERE). Boundaries are explicit so that words like `maintenance`,
# `developer` or `hcloud-agent` never trigger a rule.
RE_HCLOUD="(^|[[:space:];&|(])hcloud([[:space:]]|\$)"
RE_GIT_PUSH="(^|[[:space:];&|(])git[[:space:]]+push([[:space:]]|\$)"
RE_GIT_COMMIT="(^|[[:space:];&|(])git[[:space:]]+commit([[:space:]]|\$)"
RE_PROTECTED_REF="(^|[[:space:]:/'\"])(main|develop)([[:space:]'\"]|\$)"
RE_AI_ATTRIBUTION="Co-[Aa]uthored-[Bb]y|Generated with|🤖"

# ── Rule 1: raw hcloud is forbidden (wrapper only) ──────────────────────────
if [[ "${CMD}" =~ ${RE_HCLOUD} ]] && [[ "${CMD}" != *hcloud-agent* ]]; then
  deny "Doctrina forja: la CLI cruda de Hetzner está prohibida para el agente — usá hcloud-agent.sh (wrapper con allowlist y auditoría; ya está en el PATH). Doctrina: receta operar-servidor."
fi

# Current branch, used by rules 2 and 3 (empty on detached HEAD / no repo).
BRANCH="$(git -C "${ROOT}" symbolic-ref --short HEAD 2>/dev/null || printf '')"

# ── Rule 2: no push to main/develop ─────────────────────────────────────────
if [[ "${CMD}" =~ ${RE_GIT_PUSH} ]]; then
  AFTER="${CMD#*push}"
  if [[ "${AFTER}" =~ ${RE_PROTECTED_REF} ]]; then
    deny "Gitflow forja: main y develop solo reciben cambios por Pull Request (regla flujo-git). Cortá una feature/<nombre> desde develop."
  fi
  if [ "${BRANCH}" = "main" ] || [ "${BRANCH}" = "develop" ]; then
    # No explicit main/develop in the command: deny only when the push has no
    # refspec pointing elsewhere (a bare push would publish the current,
    # protected, branch). Tokens: after skipping flags, #1 is the remote and
    # #2+ are refspecs; HEAD still means "current branch", not elsewhere.
    SEPARATORS=$'\n;&|()'
    PUSH_ARGS="${AFTER%%[${SEPARATORS}]*}"
    TOKEN_INDEX=0
    HAS_ELSEWHERE_REFSPEC=0
    for tok in ${PUSH_ARGS}; do
      case "${tok}" in
        -*) continue ;;
      esac
      TOKEN_INDEX=$((TOKEN_INDEX + 1))
      if [ "${TOKEN_INDEX}" -ge 2 ] && [ "${tok}" != "HEAD" ]; then
        HAS_ELSEWHERE_REFSPEC=1
      fi
    done
    if [ "${HAS_ELSEWHERE_REFSPEC}" -eq 0 ]; then
      deny "Gitflow forja: main y develop solo reciben cambios por Pull Request (regla flujo-git). Cortá una feature/<nombre> desde develop."
    fi
  fi
fi

# ── Rule 3: no commit while standing on main/develop ────────────────────────
if [[ "${CMD}" =~ ${RE_GIT_COMMIT} ]]; then
  if [ "${BRANCH}" = "main" ] || [ "${BRANCH}" = "develop" ]; then
    # Empty repo (no HEAD yet) is the bootstrap exception: /forja:init makes
    # its first commit directly on main.
    if git -C "${ROOT}" rev-parse HEAD >/dev/null 2>&1; then
      deny "Gitflow forja: no se commitea directo en main/develop — cortá feature/<nombre> desde develop."
    fi
  fi
fi

# ── Rule 4: no AI attribution in commit messages ────────────────────────────
if [[ "${CMD}" =~ ${RE_GIT_COMMIT} ]] && [[ "${CMD}" =~ ${RE_AI_ATTRIBUTION} ]]; then
  deny "Regla de commits forja: sin atribución de IA en los mensajes (Conventional Commits en inglés, un commit = una unidad de trabajo). Reintentá sin el trailer."
fi

# Allow: silent.
exit 0
