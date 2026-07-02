---
description: Diagnóstico forja - verificar herramientas, preflight de entorno y conformidad del proyecto. Check forja setup, verify tools, environment diagnosis.
---

# /forja:doctor

Diagnóstico de solo-lectura: verificás herramientas y conformidad del proyecto con la doctrina forja. **NUNCA modifiques nada** — este comando diagnostica y recomienda; arreglar es decisión del usuario.

## Paso 1 — Herramientas (mismo preflight que /forja:init, solo lectura)

Corré todo en UN bloque de bash:

```bash
echo "== git =="; git --version || echo "DOCTOR_FAIL git"
echo "== node =="; node -v || echo "DOCTOR_FAIL node"
echo "== pnpm =="; pnpm -v || echo "DOCTOR_FAIL pnpm"
echo "== gh =="; gh --version && gh auth status || echo "DOCTOR_WARN gh"
echo "== docker =="; docker version --format '{{.Server.Version}}' || echo "DOCTOR_WARN docker"
echo "== gentle-ai =="; command -v gentle-ai || echo "DOCTOR_WARN gentle-ai"
echo "== engram =="; claude mcp list 2>/dev/null | grep -qi engram && echo "engram OK" || echo "DOCTOR_WARN engram"
echo "== hcloud (opcional, solo infra) =="; command -v hcloud || echo "DOCTOR_INFO hcloud ausente"
echo "== wrapper infra =="; ls "${CLAUDE_PLUGIN_ROOT}/bin/hcloud-agent.sh" 2>/dev/null || echo "DOCTOR_INFO wrapper en el bin/ del plugin forja"
```

La línea del wrapper imprime la **ruta exacta** de `hcloud-agent.sh` — esa es la que se usa para operar infra (nunca `hcloud` crudo; la guardia del plugin lo bloquea).

## Paso 2 — Conformidad del proyecto (solo si estás parado en un proyecto)

Si el directorio actual es un repo git con intención de ser proyecto forja, verificá:

```bash
echo "== .forja.json =="; node -p 'JSON.parse(require("fs").readFileSync(".forja.json","utf8")).app' || echo "DOCTOR_FAIL .forja.json ausente o inválido"
echo "== gate check =="; node -p 'JSON.parse(require("fs").readFileSync("package.json","utf8")).scripts.check ? "check OK" : "DOCTOR_FAIL sin script check"'
echo "== settings de equipo =="; grep -q forja .claude/settings.json 2>/dev/null && echo "marketplace forja referenciado" || echo "DOCTOR_WARN .claude/settings.json no referencia el marketplace forja"
echo "== gitflow =="; git show-ref --verify --quiet refs/heads/main && echo "main OK" || echo "DOCTOR_WARN falta rama main"; git show-ref --verify --quiet refs/heads/develop && echo "develop OK" || echo "DOCTOR_WARN falta rama develop"
```

## Paso 3 — Reporte

Mostrá una tabla única: fila por chequeo, columna estado (PASS/WARN/FAIL) y columna **remediación** con el paso concreto:

- git/node/pnpm faltantes → comando de instalación (brew/corepack).
- gh sin auth → `gh auth login`; dos cuentas → `gh auth switch` a la correcta para la org.
- docker apagado → abrir Docker Desktop / systemctl start docker.
- gentle-ai ausente → instalarlo antes de `/sdd-init`.
- engram ausente → agregar el MCP de engram (memoria persistente).
- `.forja.json` ausente → `/forja:init` en un directorio nuevo, o crearlo a mano si el proyecto ya existe.
- sin script `check` → agregar el gate único a `package.json` (doctrina: gates y tooling).
- settings sin marketplace → agregar `extraKnownMarketplaces`/`enabledPlugins` de forja a `.claude/settings.json`.
- falta develop → `git branch develop && git push -u origin develop`.

Cerrá con un veredicto de una línea: "listo para trabajar" o "arreglá X antes de seguir".
