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

command -v node >/dev/null 2>&1 || exit 0

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
    let msg =
      "Proyecto forja: " + c.app + " (" + c.publicName + "." + c.domain + "). " +
      "Doctrina: skill forja:doctrina (recetas por tarea). " +
      "Gitflow: main/develop solo por PR — guardia activa. " +
      "Deploy SOLO con /forja:deploy; estado del equipo con /forja:status. " +
      "Infra Hetzner: hcloud-agent.sh (en PATH), nunca hcloud crudo.";
    if (missing) msg += " Faltan herramientas: " + missing + " — corré /forja:doctor.";
    if (msg.length > 700) msg = msg.slice(0, 700);
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: msg },
    }) + "\n");
  } catch {
    process.stdout.write("{}\n");
  }
' "${ROOT}/.forja.json" "${MISSING}" 2>/dev/null || printf '{}\n'

exit 0
