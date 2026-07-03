#!/usr/bin/env bash
# forja-report.sh - diagnostic collector for forja flow-failure reports.
#
# When a forja flow (/forja:init, deploy, rollback, status, doctor, or a hook)
# fails, this script gathers the environment facts a maintainer needs and prints
# a ready-to-file GitHub issue body to stdout. It NEVER opens an issue itself:
# the calling agent shows the body to the human and only runs `gh issue create`
# after explicit confirmation (see skills/report-failure/SKILL.md).
#
# Why a script and not the agent: environment versions must be MEASURED, not
# guessed. The agent hallucinating "Claude Code v1.2" defeats the whole point.
#
# Privacy: this repo is PUBLIC. Everything printed is passed through a redaction
# pass that collapses the home dir to ~ and masks common secret shapes. The
# agent is still responsible for not passing raw secrets in --error/--summary.
#
# Usage:
#   forja-report.sh [--command <cmd>] [--phase <phase>] \
#                   [--summary <text>] [--expected <text>] \
#                   [--error <text>] [--steps <text>] [--title-only]
#
# All narrative flags are optional; anything omitted becomes an explicit
# "_(completar)_" placeholder so no section is silently blank.
#
# Portability: macOS/Linux bash, no jq. plugin.json is parsed with node when
# available, with a grep fallback so a missing node never blanks the version.
set -euo pipefail

COMMAND=""
PHASE=""
SUMMARY=""
EXPECTED=""
ERROR=""
STEPS=""
TITLE_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)   COMMAND="${2:-}"; shift 2 ;;
    --phase)     PHASE="${2:-}"; shift 2 ;;
    --summary)   SUMMARY="${2:-}"; shift 2 ;;
    --expected)  EXPECTED="${2:-}"; shift 2 ;;
    --error)     ERROR="${2:-}"; shift 2 ;;
    --steps)     STEPS="${2:-}"; shift 2 ;;
    --title-only) TITLE_ONLY=1; shift ;;
    -h|--help)
      printf 'Usage: forja-report.sh [--command <cmd>] [--phase <phase>] [--summary <text>] [--expected <text>] [--error <text>] [--steps <text>] [--title-only]\n' >&2
      exit 0 ;;
    *) printf 'forja-report: WARN: ignoring unknown arg: %s\n' "$1" >&2; shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# --- redaction ---------------------------------------------------------------
# Collapse the home directory to ~ and mask common secret shapes. Fail-soft:
# if perl is missing the raw text is returned (better a report than a crash),
# and the calling skill warns the human to eyeball it before filing.
redact() {
  local text="$1"
  if command -v perl >/dev/null 2>&1; then
    printf '%s' "${text}" | HOME="${HOME:-}" perl -pe '
      my $h = $ENV{HOME};
      if (defined $h && length $h) { s/\Q$h\E/~/g; }
      s/gh[posru]_[A-Za-z0-9]{16,}/[REDACTED-TOKEN]/g;   # GitHub tokens
      s/sk-[A-Za-z0-9]{16,}/[REDACTED-TOKEN]/g;          # OpenAI-style keys
      s/AKIA[0-9A-Z]{16}/[REDACTED-AWS-KEY]/g;           # AWS access keys
      s/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED-TOKEN]/g; # Slack tokens
      s{(://[^:/@\s]+):[^@/\s]+@}{$1:[REDACTED]@}g;       # creds in URLs
    '
  else
    printf '%s' "${text}"
  fi
}

# --- environment facts (measured, never guessed) -----------------------------
first_line() { head -n1 2>/dev/null || printf ''; }

CLAUDE_VER="$(claude --version 2>/dev/null | first_line || printf '')"
[ -n "${CLAUDE_VER}" ] || CLAUDE_VER="no detectado"

GH_VER="$(gh --version 2>/dev/null | first_line || printf '')"
[ -n "${GH_VER}" ] || GH_VER="no detectado"

NODE_VER="$(node --version 2>/dev/null || printf '')"
[ -n "${NODE_VER}" ] || NODE_VER="no detectado"

GIT_VER="$(git --version 2>/dev/null || printf '')"
[ -n "${GIT_VER}" ] || GIT_VER="no detectado"

# OS: kernel line always, plus a friendlier product name per platform.
OS_KERNEL="$(uname -srm 2>/dev/null || printf 'desconocido')"
OS_PRETTY="${OS_KERNEL}"
case "$(uname -s 2>/dev/null || printf '')" in
  Darwin)
    if command -v sw_vers >/dev/null 2>&1; then
      OS_PRETTY="macOS $(sw_vers -productVersion 2>/dev/null || printf '?') ($(uname -m 2>/dev/null || printf '?'))"
    fi ;;
  Linux)
    if [ -r /etc/os-release ]; then
      # shellcheck disable=SC1091
      OS_PRETTY="$(. /etc/os-release 2>/dev/null && printf '%s (%s)' "${PRETTY_NAME:-Linux}" "$(uname -m 2>/dev/null || printf '?')")"
    fi ;;
esac

# Plugin version from the manifest: node first, grep fallback.
MANIFEST="${PLUGIN_ROOT}/.claude-plugin/plugin.json"
PLUGIN_VER="desconocida"
if [ -r "${MANIFEST}" ]; then
  if command -v node >/dev/null 2>&1; then
    PLUGIN_VER="$(node -e 'try{process.stdout.write(String(require(process.argv[1]).version||""))}catch{}' "${MANIFEST}" 2>/dev/null || printf '')"
  fi
  if [ -z "${PLUGIN_VER}" ]; then
    PLUGIN_VER="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "${MANIFEST}" 2>/dev/null | first_line | grep -o '"[^"]*"$' | tr -d '"' || printf '')"
  fi
  [ -n "${PLUGIN_VER}" ] || PLUGIN_VER="desconocida"
fi

# Git context of the failing session (branch + short sha), never the remote URL.
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'n/a')"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || printf 'n/a')"

# --- title -------------------------------------------------------------------
TITLE_CMD="${COMMAND:-flujo forja}"
TITLE="[flow-failure] ${TITLE_CMD}${PHASE:+ — ${PHASE}}"
TITLE="$(redact "${TITLE}")"

if [ "${TITLE_ONLY}" -eq 1 ]; then
  printf '%s\n' "${TITLE}"
  exit 0
fi

# --- placeholders for omitted narrative --------------------------------------
ph() { if [ -n "$1" ]; then redact "$1"; else printf '_(completar)_'; fi; }

SUMMARY_OUT="$(ph "${SUMMARY}")"
EXPECTED_OUT="$(ph "${EXPECTED}")"
STEPS_OUT="$(ph "${STEPS}")"
COMMAND_OUT="$(ph "${COMMAND}")"
PHASE_OUT="$(ph "${PHASE}")"

if [ -n "${ERROR}" ]; then
  ERROR_OUT="$(redact "${ERROR}")"
else
  ERROR_OUT="_(pegá la salida del error, ya redactada)_"
fi

# --- body --------------------------------------------------------------------
cat <<EOF
> Reporte generado por \`scripts/forja-report.sh\`. Revisá que no queden datos sensibles antes de publicar — este repo es PÚBLICO.

## Qué falló

- **Comando/flujo:** ${COMMAND_OUT}
- **Fase:** ${PHASE_OUT}

${SUMMARY_OUT}

## Qué esperaba que pasara

${EXPECTED_OUT}

## Pasos para reproducir

${STEPS_OUT}

## Error / logs

\`\`\`
${ERROR_OUT}
\`\`\`

## Entorno

| Componente | Versión |
| --- | --- |
| Claude Code | ${CLAUDE_VER} |
| Plugin forja | ${PLUGIN_VER} |
| Sistema operativo | ${OS_PRETTY} |
| Kernel | ${OS_KERNEL} |
| gh | ${GH_VER} |
| node | ${NODE_VER} |
| git | ${GIT_VER} |
| Rama / commit | ${GIT_BRANCH} @ ${GIT_SHA} |
EOF
