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
( engram sync --cloud --status --project "${PROJECT}" >"${TMP}" 2>&1 ) &
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
      const bad = {
        blocked_unenrolled: "not_enrolled", auth_required: "auth",
        policy_forbidden: "forbidden", cloud_config_error: "not_configured",
        cloud_not_configured: "not_configured", project_required: "not_configured",
        transport_failed: "unreachable", paused: "disabled",
      };
      // Future/JSON output: explicit enabled + reason_code fields.
      try {
        const j = JSON.parse(d);
        if (j.reason_code && bad[j.reason_code]) return out("RECOMMEND:" + bad[j.reason_code]);
        if (j.enabled === true) return out("OK");
        if (j.enabled === false) return out("RECOMMEND:disabled");
      } catch {}
      // engram CLI >= 1.17 prints HUMAN TEXT (no enabled/reason_code, no --json):
      //   "Cloud sync status (project=...): Local chunks: N / Remote chunks: N / Pending import: N"
      const t = d.toLowerCase();
      if (/blocked_unenrolled|not enrolled|enroll the project/.test(t)) return out("RECOMMEND:not_enrolled");
      if (/unauthor|\b401\b|invalid token/.test(t)) return out("RECOMMEND:auth");
      if (/forbidden|\b403\b|access denied/.test(t)) return out("RECOMMEND:forbidden");
      if (/cloud sync status|remote chunks/.test(t)) return out("OK");
      if (/refused|timed?\s?out|could not|unreachable|no route|failed to (connect|reach)/.test(t)) return out("RECOMMEND:unreachable");
      return out("RECOMMEND:unreachable");
    });
  ' 2>/dev/null || printf '')"
fi

case "${TOKEN}" in
  OK)            emit "ENGRAM_CLOUD_OK" ;;
  RECOMMEND:*)   emit "ENGRAM_CLOUD_${TOKEN}" ;;
  *)
    # Fallback without node. Plain-text (CLI >=1.17) success shows the status
    # header / "Remote chunks"; JSON shows enabled:true.
    case "${STATUS_OUT}" in
      *'"enabled": true'*|*'enabled=true'*|*'Cloud sync status'*|*'Remote chunks'*) emit "ENGRAM_CLOUD_OK" ;;
      *blocked_unenrolled*|*'not enrolled'*) emit "ENGRAM_CLOUD_RECOMMEND:not_enrolled" ;;
      *auth_required*|*nauthor*)             emit "ENGRAM_CLOUD_RECOMMEND:auth" ;;
      *) emit "ENGRAM_CLOUD_RECOMMEND:unreachable" ;;
    esac ;;
esac
