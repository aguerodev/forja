#!/usr/bin/env bash
# scripts/release/versions.sh — list rollback candidates (ops/08).
# Multi-version rollback needs DESCRIPTIONS, not timestamps: each image was
# built with --build-arg GIT_SHA=<commit>, which the runner stage bakes as
# the BUILD_SHA env — zero extra metadata. This script reads it back from
# each tagged image and resolves it to `git log -1 '%h %s'` when the commit
# exists locally, and marks the version currently running.
#
# Usage: versions.sh <production|preview>
#
# Lists node-side image tags:
#   <env>-<utc-ts>  rollback history (created by deploy.sh after a HEALTHY
#                   deploy; pruned to the last 5)
#   vX.Y.Z          release tags (production only)
# The running version (service ${STACK}_app image) is marked with '*'.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "${FORJA_ROOT}"

[ -n "${1:-}" ] || { printf 'Usage: versions.sh <production|preview>\n' >&2; exit 2; }
env_ctx "$1"

if ! all_tags="$(dk image ls --format '{{.Tag}}|{{.CreatedAt}}' "${APP}" 2>&1)"; then
  fail "cannot query the ${ENV_NAME} docker engine (context: ${DOCKER_CONTEXT:-local}): ${all_tags}"
fi

# <env>-* first (newest first), then v* release tags.
env_tags="$(printf '%s\n' "${all_tags}" | grep -E "^${TAG_PREFIX}-" | sort -r || true)"
ver_tags="$(printf '%s\n' "${all_tags}" | grep -E '^v[0-9]' | sort -r || true)"
rollback_tags="$(printf '%s\n%s\n' "${env_tags}" "${ver_tags}" | grep -v '^$' || true)"

if [ -z "${rollback_tags}" ]; then
  log "no rollback versions for ${ENV_NAME} yet (stack ${STACK})"
  log "rollback tags (${TAG_PREFIX}-<utc-ts>, plus vX.Y.Z in production) are created by deploy.sh after each HEALTHY deploy — they will appear after the first successful deploy of this environment"
  exit 0
fi

running_image="$(dk service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' "${STACK}_app" 2>/dev/null || true)"
running_image="${running_image%%@*}"   # drop the digest pin, keep repo:tag
[ -n "${running_image}" ] || warn "service ${STACK}_app is not running — no version marked as current"

printf '\nRollback candidates for %s (stack %s, image %s):\n' "${ENV_NAME}" "${STACK}" "${APP}"
printf '  %s = running\n\n' '*'

while IFS='|' read -r tag created; do
  [ -n "${tag}" ] || continue
  created_short="$(printf '%s' "${created}" | awk '{print $1 " " $2}')"

  # BUILD_SHA baked at build time (Dockerfile runner stage: ENV BUILD_SHA=$GIT_SHA).
  sha="$(dk image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${APP}:${tag}" 2>/dev/null \
    | awk -F= '/^BUILD_SHA=/ { print $2; exit }' || true)"

  if [ -z "${sha}" ]; then
    desc="(image carries no BUILD_SHA)"
  elif [ "${sha}" = "dev" ]; then
    desc="(built without GIT_SHA)"
  elif git cat-file -e "${sha}^{commit}" 2>/dev/null; then
    desc="$(git log -1 --format='%h %s' "${sha}")"
  else
    desc="(commit ${sha} not in local history — fetch first)"
  fi

  marker=" "
  if [ -n "${running_image}" ] && [ "${APP}:${tag}" = "${running_image}" ]; then
    marker="*"
  fi

  printf ' %s %-24s %-17s %s\n' "${marker}" "${tag}" "${created_short}" "${desc}"
done <<EOF_TAGS
${rollback_tags}
EOF_TAGS

printf '\nRoll back with: bash scripts/release/rollback-to.sh %s <tag|latest>\n' "${ENV_NAME}"
