#!/usr/bin/env bash
# engram-cloud-check.sh - shared engram-cloud readiness detector for forja.
#
# Single source of truth used by BOTH the SessionStart hook (session-context.sh)
# and /forja:doctor. engram-cloud (Gentleman-Programming/engram, docs/engram-cloud)
# is a self-hosted replication server for team memory. It is RECOMMENDED, not
# required: this script never blocks — it only reports readiness so the caller can
# nudge the user to configure it.
#
# Contract: prints exactly ONE token on the first line and exits 0 (fail-soft).
#   ENGRAM_CLOUD_OK              - configured, enrolled and connected
#   ENGRAM_CLOUD_RECOMMEND:<r>   - not ready; <r> refines the nudge/remediation
#   ENGRAM_CLOUD_NA              - not a forja project (scope gate); stay silent
# Reasons (<r>): cli_missing, cli_no_cloud, not_configured, not_enrolled, auth,
#   forbidden, unreachable, disabled.
#
# Design: touches the network (status query) so it uses a short, portable timeout
# (macOS has no `timeout`) and degrades any failure to RECOMMEND:unreachable — the
# session start must never hang or break. JSON is parsed with node (+ a lenient
# regex fallback), mirroring session-context.sh.
set -u

emit() { printf '%s\n' "$1"; exit 0; }

# --- resolve project root (arg, else git toplevel, else cwd) ------------------
ROOT="${1:-}"
if [ -z "${ROOT}" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "${PWD}")"
fi

# Scope gate: only ever speaks inside a forja project.
[ -f "${ROOT}/.forja.json" ] || emit "ENGRAM_CLOUD_NA"

# --- engram CLI presence + cloud support -------------------------------------
command -v engram >/dev/null 2>&1 || emit "ENGRAM_CLOUD_RECOMMEND:cli_missing"
# A binary too old to know `cloud` can't participate. `engram cloud --help`
# returns non-zero when the subcommand is unknown.
engram cloud --help >/dev/null 2>&1 || emit "ENGRAM_CLOUD_RECOMMEND:cli_no_cloud"

# --- cloud config file (engram cloud config --server ...) --------------------
CLOUD_JSON="${HOME:-}/.engram/cloud.json"
[ -f "${CLOUD_JSON}" ] || emit "ENGRAM_CLOUD_RECOMMEND:not_configured"

# --- resolve the project name (.engram/config.json, else .forja.json app) ----
PROJECT=""
if command -v node >/dev/null 2>&1; then
  PROJECT="$(node -e '
    const fs = require("fs");
    const read = (p, k) => { try { return String(JSON.parse(fs.readFileSync(p,"utf8"))[k] || ""); } catch { return ""; } };
    process.stdout.write(read(process.argv[1],"project_name") || read(process.argv[2],"app"));
  ' "${ROOT}/.engram/config.json" "${ROOT}/.forja.json" 2>/dev/null || printf '')"
fi
# Without a project we cannot query per-project status; nudge to configure.
[ -n "${PROJECT}" ] || emit "ENGRAM_CLOUD_RECOMMEND:not_configured"

# --- query cloud sync status with a short, portable timeout ------------------
# Run in background and kill after N seconds so the hook never hangs offline.
STATUS_OUT=""
TMP="$(mktemp 2>/dev/null || printf '/tmp/engram-cloud-%s' "$$")"
( engram sync --cloud --status --project "${PROJECT}" >"${TMP}" 2>/dev/null ) &
qpid=$!
waited=0
while kill -0 "${qpid}" 2>/dev/null; do
  sleep 1
  waited=$((waited + 1))
  if [ "${waited}" -ge 3 ]; then
    kill "${qpid}" 2>/dev/null
    wait "${qpid}" 2>/dev/null
    rm -f "${TMP}"
    emit "ENGRAM_CLOUD_RECOMMEND:unreachable"
  fi
done
wait "${qpid}" 2>/dev/null
STATUS_OUT="$(cat "${TMP}" 2>/dev/null || printf '')"
rm -f "${TMP}"

[ -n "${STATUS_OUT}" ] || emit "ENGRAM_CLOUD_RECOMMEND:unreachable"

# --- classify the status payload (node JSON, lenient regex fallback) ----------
# No documented exit codes -> parse the enabled/reason_code fields. Any parse
# failure degrades to unreachable (a nudge, never a block).
TOKEN=""
if command -v node >/dev/null 2>&1; then
  TOKEN="$(printf '%s' "${STATUS_OUT}" | node -e '
    let d = ""; process.stdin.on("data", c => d += c); process.stdin.on("end", () => {
      const out = (t) => { process.stdout.write(t); process.exit(0); };
      let enabled, reason;
      try { const j = JSON.parse(d); enabled = j.enabled; reason = j.reason_code; }
      catch {
        const m = d.match(/reason_code["\s:]+([a-z_]+)/i); if (m) reason = m[1];
        if (/"?enabled"?\s*[:=]\s*true/i.test(d)) enabled = true;
        else if (/"?enabled"?\s*[:=]\s*false/i.test(d)) enabled = false;
      }
      const bad = {
        blocked_unenrolled: "not_enrolled", auth_required: "auth",
        policy_forbidden: "forbidden", cloud_config_error: "not_configured",
        cloud_not_configured: "not_configured", project_required: "not_configured",
        transport_failed: "unreachable", paused: "disabled",
      };
      if (reason && bad[reason]) return out("RECOMMEND:" + bad[reason]);
      if (enabled === true) return out("OK");
      if (enabled === false) return out("RECOMMEND:disabled");
      return out("RECOMMEND:unreachable");
    });
  ' 2>/dev/null || printf '')"
fi

case "${TOKEN}" in
  OK)            emit "ENGRAM_CLOUD_OK" ;;
  RECOMMEND:*)   emit "ENGRAM_CLOUD_${TOKEN}" ;;
  *)
    # Fallback without node: a payload mentioning enrolled/enabled is a good sign.
    case "${STATUS_OUT}" in
      *'"enabled": true'*|*'enabled=true'*) emit "ENGRAM_CLOUD_OK" ;;
      *blocked_unenrolled*) emit "ENGRAM_CLOUD_RECOMMEND:not_enrolled" ;;
      *auth_required*)      emit "ENGRAM_CLOUD_RECOMMEND:auth" ;;
      *) emit "ENGRAM_CLOUD_RECOMMEND:unreachable" ;;
    esac ;;
esac
