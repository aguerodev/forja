#!/usr/bin/env bash
# bash-guard.sh - PreToolUse(Bash) guard for the forja plugin.
#
# Thin wrapper: the whole analysis lives in bash-guard.js (segment-aware
# parsing with quote handling - see that file for the rule set). Rules apply
# only inside forja projects (repo root contains .forja.json); the scope gate
# itself is enforced in the JS.
#
# Contract: stdin gets the hook payload JSON; a deny answers with
# permissionDecision JSON on stdout; an allow exits 0 with no output.
# Fail-open by design: any missing dependency or parse error must never
# block work (exit 0, silent).
set -u

# Fail open if node (the analysis runtime) is unavailable — but leave a trace.
if ! command -v node >/dev/null 2>&1; then
  printf 'forja bash-guard: node ausente - guardias INACTIVAS (fail-open)\n' >&2
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# stderr passes through: on an internal guard error the JS leaves a one-line
# trace there (visible in verbose/debug) instead of dying in silence.
node "${SCRIPT_DIR}/bash-guard.js" || exit 0
exit 0
