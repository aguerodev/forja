#!/usr/bin/env bash
# scripts/release/tag-release.sh — cut the release record (ops/08 step 10).
# The tag is the RECORD of what reached prod, never a trigger. The annotated
# body IS the changelog: commits since the previous v* tag, so "what changed
# between vX and vY" is answered by `git tag -n99 vX.Y.Z` / `git show vX.Y.Z`
# — no hand-maintained CHANGELOG.md drifting out of date.
#
# Contract:
#   - tag = v<project version> (the contract version command; a single datum)
#   - annotated, body = `git log <prev-tag>..HEAD --oneline` (full history
#     for the very first release)
#   - only from main
#   - idempotent: the tag already on HEAD -> [PASS], exit 0
#   - the tag existing on ANOTHER commit -> [FAIL], exit 1 (bump the version)
#   - does NOT push unless PUSH_TAG=1 (then: git push origin vX.Y.Z)
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_cmd git
cd "${FORJA_ROOT}"

branch="$(git rev-parse --abbrev-ref HEAD)"
[ "${branch}" = "main" ] \
  || fail "tag-release runs only from main (current branch: ${branch}) — the tag records what reached prod"

version="$(project_version)"
tag="v${version}"
head_sha="$(git rev-parse HEAD)"

if existing="$(git rev-parse -q --verify "refs/tags/${tag}^{commit}" 2>/dev/null)"; then
  if [ "${existing}" = "${head_sha}" ]; then
    pass "tag ${tag} already exists on HEAD — release already recorded (idempotent)"
    exit 0
  fi
  fail "tag ${tag} already exists on $(git rev-parse --short "${existing}") but HEAD is $(git rev-parse --short "${head_sha}") — bump the project version (the datum read by commands.version) on a release/* branch before tagging"
fi

prev_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)"
if [ -n "${prev_tag}" ]; then
  changelog="$(git log --format='%h %s' "${prev_tag}..HEAD")"
  range_label="changes since ${prev_tag}"
else
  changelog="$(git log --format='%h %s')"
  range_label="first release — full history"
fi
[ -n "${changelog}" ] || changelog="(no commits in range)"

git tag -a "${tag}" -m "Release ${tag} (${range_label})" -m "${changelog}"
pass "created annotated tag ${tag} on $(git rev-parse --short HEAD) — body: ${range_label}"

if [ "${PUSH_TAG:-0}" = "1" ]; then
  git push origin "${tag}"
  pass "pushed ${tag} to origin"
else
  log "tag NOT pushed (set PUSH_TAG=1 to push origin ${tag})"
fi
