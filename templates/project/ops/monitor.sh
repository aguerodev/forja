#!/usr/bin/env bash
# ops/monitor.sh — the mandatory monitoring minimum for the node (ops/10).
# Install (4 steps, as root on the node):
#   cp ops/monitor.sh /usr/local/bin/forja-monitor.sh && chmod +x /usr/local/bin/forja-monitor.sh
#   cp ops/systemd/forja-monitor.service ops/systemd/forja-monitor.timer /etc/systemd/system/
#   printf 'MONITOR_WEBHOOK_URL=<ntfy/slack/telegram webhook>\n' > /etc/forja-monitor.env && chmod 600 /etc/forja-monitor.env
#   systemctl daemon-reload && systemctl enable --now forja-monitor.timer
#
# The node must not be born blind: a systemd timer (~15 min) runs this script,
# which measures — thresholds WARN > MONITOR_WARN (80), CRIT > MONITOR_CRIT (90):
#   - rootfs bytes %      (df -P /)
#   - rootfs inodes %     (df -iP /)   inodes run out FIRST on docker hosts
#   - memory used %       (free -m; /proc/meminfo fallback)
# and reports as context (no thresholds):
#   - docker system df
#   - du of the *_pgdata volume(s)
#
# On WARN/CRIT it POSTs JSON {hostname, level, details, timestamp} to
# $MONITOR_WEBHOOK_URL (loaded from /etc/forja-monitor.env, mode 600, unless
# already in the environment). THE JOURNAL IS NOT AN ALERT — with no webhook
# configured this is log-only and says so explicitly.
#
# Always exits 0: the timer must keep firing; measurement/delivery problems
# are logged, never turned into a failed unit that nobody watches either.
#
# Overrides: MONITOR_WARN, MONITOR_CRIT (integers, %), MONITOR_ENV_FILE.
set -euo pipefail

MONITOR_ENV_FILE="${MONITOR_ENV_FILE:-/etc/forja-monitor.env}"
if [ -z "${MONITOR_WEBHOOK_URL:-}" ] && [ -r "${MONITOR_ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${MONITOR_ENV_FILE}"
fi
MONITOR_WARN="${MONITOR_WARN:-80}"
MONITOR_CRIT="${MONITOR_CRIT:-90}"

LEVEL="OK"
DETAILS=""

note() { printf '%s\n' "$*"; }

escalate() { # $1 = WARN|CRIT
  case "$1" in
    CRIT) LEVEL="CRIT" ;;
    WARN) [ "${LEVEL}" = "CRIT" ] || LEVEL="WARN" ;;
  esac
}

check_pct() { # $1 = label, $2 = integer percentage
  local status line
  # Some filesystems (overlayfs in containers) report '-' instead of a
  # number; skip the threshold rather than crash the pass.
  case "$2" in
    ''|*[!0-9]*)
      note "SKIP ${1}: no numeric reading from df (got '${2:-empty}')"
      return 0
      ;;
  esac
  status="OK"
  if [ "$2" -gt "${MONITOR_CRIT}" ]; then
    status="CRIT"
  elif [ "$2" -gt "${MONITOR_WARN}" ]; then
    status="WARN"
  fi
  line="${status} ${1}: ${2}% (warn>${MONITOR_WARN} crit>${MONITOR_CRIT})"
  note "${line}"
  if [ "${status}" != "OK" ]; then
    escalate "${status}"
    DETAILS="${DETAILS}${line}; "
  fi
}

# ── Thresholded metrics ──────────────────────────────────────────────────────
rootfs_pct="$(df -P / | awk 'NR==2 { sub(/%/, "", $5); print $5 }')"
check_pct "rootfs bytes" "${rootfs_pct}"

inode_pct="$(df -iP / | awk 'NR==2 { sub(/%/, "", $5); print $5 }')"
check_pct "rootfs inodes" "${inode_pct}"

if command -v free >/dev/null 2>&1; then
  mem_pct="$(free -m | awk 'NR==2 { printf "%d", ($3 * 100) / $2 }')"
else
  # Minimal environments may lack procps — derive the same figure from
  # /proc/meminfo (used = total - available).
  mem_pct="$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { if (t > 0) printf "%d", ((t - a) * 100) / t; else print 0 }' /proc/meminfo)"
fi
check_pct "memory used" "${mem_pct}"

# ── Report-only context ──────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  note "docker system df:"
  docker system df 2>&1 | awk '{ print "  " $0 }' || true
  pg_volumes="$(docker volume ls -q 2>/dev/null | grep '_pgdata$' || true)"
  if [ -n "${pg_volumes}" ]; then
    for vol in ${pg_volumes}; do
      mountpoint="$(docker volume inspect --format '{{.Mountpoint}}' "${vol}" 2>/dev/null || true)"
      if [ -n "${mountpoint}" ] && [ -d "${mountpoint}" ]; then
        note "pgdata ${vol}: $(du -sh "${mountpoint}" 2>/dev/null | awk '{print $1}' || printf '?')"
      fi
    done
  else
    note "pgdata: no *_pgdata volume found"
  fi
else
  note "docker not available — docker system df / pgdata report skipped"
fi

# ── Level + alert ────────────────────────────────────────────────────────────
host_name="$(hostname 2>/dev/null || uname -n)"
note "level: ${LEVEL}"

if [ "${LEVEL}" != "OK" ]; then
  if [ -n "${MONITOR_WEBHOOK_URL:-}" ]; then
    payload="$(printf '{"hostname":"%s","level":"%s","details":"%s","timestamp":"%s"}' \
      "${host_name}" "${LEVEL}" "${DETAILS}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
    if curl -fsS -m 15 -H 'Content-Type: application/json' -d "${payload}" \
      "${MONITOR_WEBHOOK_URL}" >/dev/null 2>&1; then
      note "alert posted to webhook (${LEVEL})"
    else
      note "ERROR: webhook POST failed — the ${LEVEL} alert was NOT delivered (the journal is not an alert)"
    fi
  else
    note "WARNING: MONITOR_WEBHOOK_URL not set — this ${LEVEL} is log-only and nobody will see it (configure /etc/forja-monitor.env, mode 600)"
  fi
fi

exit 0
