---
description: Instalar la statusline de forja en la config del usuario (~/.claude). Segmentos dir | rama | modelo | contexto% | estado git. Install forja statusline.
---

# /forja:statusline

Instala la **statusline de forja** en la config global del usuario (`~/.claude/`): una barra de estado minimal con `directorio │ rama │ modelo │ contexto% │ estado git │ commits atrasados`. Afecta TODAS las sesiones de Claude Code del developer (la statusline es UX por-dev, no por-proyecto).

**Frontera:** este comando SÍ escribe en `~/.claude/settings.json` — pero **siempre con backup previo**, preservando el resto de la config, y **nunca** pisa una statusline existente sin avisar. Claude Code no permite que un plugin apunte a un script empaquetado desde el `command` de la statusLine (`${CLAUDE_PLUGIN_ROOT}` no está disponible ahí), por eso el script se **copia** a `~/.claude/statusline.sh`.

## Paso 1 — Preflight

```bash
echo "== jq (requerido por la statusline) =="; command -v jq >/dev/null 2>&1 && jq --version || echo "DOCTOR_WARN jq ausente — la statusline no renderiza sin jq (brew install jq)"
echo "== script empaquetado =="; ls "${CLAUDE_PLUGIN_ROOT}/bin/statusline.sh" >/dev/null 2>&1 && echo "OK" || echo "DOCTOR_FAIL no encuentro el script del plugin"
echo "== statusLine actual (si ya hay una) =="; node -p 'JSON.stringify((()=>{try{return JSON.parse(require("fs").readFileSync(process.env.HOME+"/.claude/settings.json","utf8")).statusLine||null}catch{return null}})())' 2>/dev/null
```

Si el Paso 1 muestra una `statusLine` YA configurada y **no** es la de forja (`~/.claude/statusline.sh`), **mostrásela al usuario y confirmá** antes de continuar — el backup la conserva, pero el usuario decide si la reemplaza.

## Paso 2 — Instalar (copia + merge idempotente con backup)

```bash
set -e
mkdir -p "$HOME/.claude"
# backup con timestamp si el settings.json ya existe
if [ -f "$HOME/.claude/settings.json" ]; then
  cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.bak.$(date +%Y%m%d%H%M%S)"
fi
# copiar el script empaquetado y hacerlo ejecutable
cp "${CLAUDE_PLUGIN_ROOT}/bin/statusline.sh" "$HOME/.claude/statusline.sh"
chmod +x "$HOME/.claude/statusline.sh"
# merge de la clave statusLine, preservando el resto de la config
node -e '
  const fs = require("fs");
  const p = process.env.HOME + "/.claude/settings.json";
  let j = {};
  if (fs.existsSync(p)) {
    const raw = fs.readFileSync(p, "utf8");
    if (raw.trim()) {
      try {
        j = JSON.parse(raw);
      } catch (e) {
        // NO sobrescribir un settings.json que no parsea (p. ej. con comentarios):
        // perderiamos la config del usuario. Abortar y que lo revise (hay backup).
        console.error("[FAIL] " + p + " no es JSON valido — no lo toco. Revisalo a mano o restaura del backup.");
        process.exit(1);
      }
    }
  }
  j.statusLine = { type: "command", command: "~/.claude/statusline.sh", padding: 0 };
  fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
  console.log("statusLine seteada en", p);
'
```

## Paso 3 — Confirmar

Contale al usuario que la statusline quedó instalada y que **se ve en la próxima sesión** (o al reabrir la actual). Mencioná el backup creado (si hubo). Si `jq` faltaba en el Paso 1, recordale instalarlo (`brew install jq`) — sin `jq` la barra no renderiza.
