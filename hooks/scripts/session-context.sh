#!/usr/bin/env bash
# session-context.sh - SessionStart hook for the forja plugin.
#
# Reads the hook payload from stdin, and ONLY inside a forja project (a repo
# whose root contains .forja.json) injects a short Spanish context block via
# additionalContext. Outside forja projects it prints {} and stays silent.
#
# Portability: macOS/Linux bash, no jq. JSON parsing is delegated to node;
# if node is not available we exit 0 silently (never break a session).
set -u

# Degraded-context banner: static, interpolation-free JSON that is safe to
# emit without node. Used whenever we are inside a forja project but cannot
# build the real context — degrading VISIBLY beats starting a blind session.
DEGRADED_JSON='{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"ATENCIÓN forja: no pude armar el contexto de sesión (.forja.json ilegible o node ausente). La sesión arranca DEGRADADA: sin resumen del proyecto y sin importar la memoria de equipo. Corré /forja:doctor para diagnosticar."}}'

if ! command -v node >/dev/null 2>&1; then
  ROOT_NOJS="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "${PWD}")"
  if [ -f "${ROOT_NOJS}/.forja.json" ]; then
    printf '%s\n' "${DEGRADED_JSON}"
  else
    printf '{}\n'
  fi
  exit 0
fi

PAYLOAD="$(cat 2>/dev/null || printf '')"

# Extract cwd from the hook payload (empty string on any parse failure).
CWD="$(printf '%s' "${PAYLOAD}" | node -e '
  let d = "";
  process.stdin.on("data", (c) => (d += c));
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(d);
      if (typeof j.cwd === "string") process.stdout.write(j.cwd);
    } catch {}
  });
' 2>/dev/null || printf '')"
[ -n "${CWD}" ] || CWD="${PWD}"

# Project root: git toplevel when available, cwd otherwise.
ROOT="$(git -C "${CWD}" rev-parse --show-toplevel 2>/dev/null || printf '%s' "${CWD}")"

# Scope gate: never pollute non-forja sessions.
if [ ! -f "${ROOT}/.forja.json" ]; then
  printf '{}\n'
  exit 0
fi

# Team memory: import chunks committed by teammates. Local-only operation
# (no network) and strictly fail-soft: any failure leaves the session as-is.
ENGRAM_NOTE=""
if [ -f "${ROOT}/.engram/manifest.json" ]; then
  if command -v engram >/dev/null 2>&1; then
    IMPORT_OUT="$( (cd "${ROOT}" && engram sync --import) 2>/dev/null )" || IMPORT_OUT=""
    case "${IMPORT_OUT}" in
      "") ENGRAM_NOTE="" ;;
      *"No new chunks"*) ENGRAM_NOTE="Memoria de equipo (engram): al día." ;;
      *) ENGRAM_NOTE="Memoria de equipo (engram): chunks nuevos importados." ;;
    esac
  else
    ENGRAM_NOTE="Hay memoria de equipo en .engram/ pero falta el CLI de engram — instalalo para importar/exportar."
  fi
fi

# engram-cloud readiness: a RECOMMENDATION only (never blocks the session).
# Delegated to the shared detector so doctor and this hook agree. Fail-soft:
# any failure leaves CLOUD_NOTE empty and the session starts as usual.
CLOUD_NOTE=""
CLOUD_TOKEN="$( "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/engram-cloud-check.sh" "${ROOT}" 2>/dev/null || printf '' )"
case "${CLOUD_TOKEN}" in
  ENGRAM_CLOUD_OK) CLOUD_NOTE="Memoria de equipo (engram-cloud): conectada." ;;
  ENGRAM_CLOUD_RECOMMEND:not_enrolled) CLOUD_NOTE="engram-cloud casi listo: enrolá el proyecto — engram cloud enroll <proyecto>." ;;
  ENGRAM_CLOUD_RECOMMEND:cli_missing|ENGRAM_CLOUD_RECOMMEND:cli_no_cloud) CLOUD_NOTE="engram-cloud recomendado para memoria de equipo: instalá/actualizá el binario engram con soporte cloud." ;;
  ENGRAM_CLOUD_RECOMMEND:auth) CLOUD_NOTE="engram-cloud: token inválido — exportá ENGRAM_CLOUD_TOKEN (o /forja:doctor)." ;;
  ENGRAM_CLOUD_RECOMMEND:unreachable) CLOUD_NOTE="engram-cloud configurado pero no pude verificarlo (¿server u offline?) — /forja:doctor." ;;
  ENGRAM_CLOUD_RECOMMEND:*) CLOUD_NOTE="engram-cloud recomendado para compartir memoria de equipo: engram cloud config --server <url> (o /forja:doctor)." ;;
  *) CLOUD_NOTE="" ;;
esac

# Tooling check for the context message.
MISSING=""
for t in gentle-ai gh docker hcloud; do
  command -v "${t}" >/dev/null 2>&1 || MISSING="${MISSING:+${MISSING}, }${t}"
done

# Build the hook JSON in node so escaping and the 700-char cap are guaranteed.
node -e '
  const fs = require("fs");
  try {
    const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const missing = process.argv[2] || "";
    const engramNote = process.argv[3] || "";
    const cloudNote = process.argv[4] || "";
    const root = process.env.CLAUDE_PLUGIN_ROOT || "";
    const wrapper = root
      ? root + "/bin/hcloud-agent.sh"
      : "el wrapper hcloud-agent.sh del plugin forja (/forja:doctor muestra la ruta)";
    let msg =
      "Proyecto forja: " + c.app + " (" + c.publicName + "." + c.domain + "). " +
      "Doctrina: skill forja:doctrina (recetas por tarea). " +
      "Gitflow: main/develop solo por PR — guardia activa. " +
      "Deploy SOLO con /forja:deploy; estado del equipo con /forja:status. " +
      "Infra Hetzner: usá " + wrapper + " — nunca hcloud crudo.";
    if (engramNote) msg += " " + engramNote;
    if (cloudNote) msg += " 💡 " + cloudNote;
    if (missing) msg += " Faltan herramientas: " + missing + " — corré /forja:doctor.";
    if (msg.length > 700) msg = msg.slice(0, 700);
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: msg },
    }) + "\n");
  } catch {
    // Signal the wrapper via exit code; it emits the static degraded banner.
    process.exit(3);
  }
' "${ROOT}/.forja.json" "${MISSING}" "${ENGRAM_NOTE}" "${CLOUD_NOTE}" 2>/dev/null || printf '%s\n' "${DEGRADED_JSON}"

exit 0
