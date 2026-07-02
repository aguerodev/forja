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

# Fail open if node (the analysis runtime) is unavailable.
command -v node >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

node "${SCRIPT_DIR}/bash-guard.js" 2>/dev/null || exit 0
exit 0
