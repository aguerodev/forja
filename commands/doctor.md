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
echo "== pnpm (solo si el contrato lo usa) =="; pnpm -v || echo "DOCTOR_WARN pnpm (necesario solo si los commands.* de .forja.json lo usan)"
echo "== gh =="; gh --version && gh auth status || echo "DOCTOR_WARN gh"
echo "== docker =="; docker version --format '{{.Server.Version}}' || echo "DOCTOR_WARN docker"
echo "== gentle-ai =="; command -v gentle-ai || echo "DOCTOR_WARN gentle-ai"
echo "== engram MCP =="; claude mcp list 2>/dev/null | grep -qi engram && echo "engram MCP OK" || echo "DOCTOR_WARN engram-mcp"
echo "== engram CLI =="; command -v engram || echo "DOCTOR_WARN engram-cli (sin binario no hay memoria de equipo)"
echo "== hcloud (opcional, solo infra) =="; command -v hcloud || echo "DOCTOR_INFO hcloud ausente"
echo "== wrapper infra =="; ls "${CLAUDE_PLUGIN_ROOT}/bin/hcloud-agent.sh" 2>/dev/null || echo "DOCTOR_INFO wrapper en el bin/ del plugin forja"
echo "== LSP servers (opcional, inteligencia de código) =="
for s in bash-language-server docker-langserver yaml-language-server; do
  command -v "$s" >/dev/null 2>&1 && echo "  $s OK" || echo "DOCTOR_INFO lsp $s ausente"
done
echo "== shellcheck/shfmt (opcional, diagnósticos del LSP de bash) =="
for s in shellcheck shfmt; do
  command -v "$s" >/dev/null 2>&1 && echo "  $s OK" || echo "DOCTOR_INFO lsp-bash $s ausente"
done
```

La línea del wrapper imprime la **ruta exacta** de `hcloud-agent.sh` — esa es la que se usa para operar infra (nunca `hcloud` crudo; la guardia del plugin lo bloquea).

## Paso 2 — Conformidad del proyecto (solo si estás parado en un proyecto)

Si el directorio actual es un repo git con intención de ser proyecto forja, verificá:

```bash
echo "== .forja.json =="; node -p 'JSON.parse(require("fs").readFileSync(".forja.json","utf8")).app' || echo "DOCTOR_FAIL .forja.json ausente o inválido"
echo "== gate check (contrato) =="; node -p 'const c=JSON.parse(require("fs").readFileSync(".forja.json","utf8")); "check: " + ((c.commands && c.commands.check) || "pnpm run check (fallback v1)")' || echo "DOCTOR_FAIL .forja.json ilegible"
echo "== settings de equipo =="; grep -q forja .claude/settings.json 2>/dev/null && echo "marketplace forja referenciado" || echo "DOCTOR_WARN .claude/settings.json no referencia el marketplace forja"
echo "== gitflow =="; git show-ref --verify --quiet refs/heads/main && echo "main OK" || echo "DOCTOR_WARN falta rama main"; git show-ref --verify --quiet refs/heads/develop && echo "develop OK" || echo "DOCTOR_WARN falta rama develop"
echo "== preview per-dev =="; DEVU="$(git config --get forja.devUser 2>/dev/null)"; [ -n "$DEVU" ] && echo "forja.devUser=$DEVU" || echo "DOCTOR_INFO forja.devUser sin setear (o vacio) - tu preview usara el label generico dev- (colisiona si hay 2+ devs)"
echo "== artifact store SDD =="; if [ -d openspec ]; then echo "openspec OK"; elif [ -d software_requirements ]; then echo "DOCTOR_WARN hay requerimientos pero NO existe openspec/ - si ya corriste sdd-init, el store quedo en engram (doctrina: openspec, los artefactos viajan en el PR)"; else echo "sin actividad SDD aun"; fi
echo "== memoria de equipo (engram) =="; node -p 'JSON.parse(require("fs").readFileSync(".engram/config.json","utf8")).project_name' 2>/dev/null || echo "DOCTOR_WARN .engram/config.json ausente"
git check-ignore -q .engram/engram.db && echo "engram.db gitignoreada OK" || echo "DOCTOR_WARN .engram/engram.db NO esta gitignoreada"
command -v engram >/dev/null 2>&1 && engram sync --status 2>/dev/null || echo "DOCTOR_INFO sin CLI engram - sync de memoria de equipo inactivo"
echo "== engram-cloud (memoria de equipo compartida, recomendado) =="; ECT="$("${CLAUDE_PLUGIN_ROOT}/hooks/scripts/engram-cloud-check.sh" 2>/dev/null)"; case "$ECT" in ENGRAM_CLOUD_OK) echo "engram-cloud conectado OK";; ENGRAM_CLOUD_RECOMMEND:*) echo "DOCTOR_WARN engram-cloud ${ECT#ENGRAM_CLOUD_RECOMMEND:} (recomendado configurar para compartir memoria de equipo)";; *) echo "engram-cloud n/a";; esac
```

Coherencia: el `project_name` de `.engram/config.json` tiene que coincidir con el `app` de `.forja.json` — si difieren, cada dev exporta a un proyecto de memoria distinto y el equipo se fragmenta.

## Paso 3 — Reporte

Mostrá una tabla única: fila por chequeo, columna estado (PASS/WARN/FAIL) y columna **remediación** con el paso concreto:

- git/node faltantes → comando de instalación (node es el runtime del tooling forja). pnpm solo si los comandos del contrato lo usan.
- gh sin auth → `gh auth login`; dos cuentas → `gh auth switch` a la correcta para la org.
- docker apagado → abrir Docker Desktop / systemctl start docker.
- gentle-ai ausente → instalarlo antes de `/sdd-init`.
- engram MCP ausente → agregar el MCP de engram (memoria persistente).
- engram CLI ausente → instalar el binario `engram` (sin él no hay memoria de equipo por git sync).
- `.engram/config.json` ausente o con `project_name` ≠ `app` → crearlo/corregirlo (`{"project_name": "<app>"}`); pinea la identidad del proyecto para todos los clones.
- `.engram/engram.db` sin gitignorear → agregar `.engram/engram.db*` al `.gitignore`; si la DB ya quedó TRACKEADA el check falla aunque el patrón exista (check-ignore consulta el índice) — ahí además va `git rm --cached '.engram/engram.db*'` en el próximo commit (la DB local jamás viaja; chunks y manifest sí).
- `Pending import` > 0 en `engram sync --status` → correr `engram sync --import` (o reabrir la sesión: el hook lo hace solo).
- engram-cloud `not_configured` (recomendado, no obligatorio) → `engram cloud config --server <url>` + `engram cloud enroll <project>`; verificá con `engram sync --cloud --status --project <project>` (debe dar `enabled: true`). Comparte la memoria de equipo por un server, complementando el git-sync de `.engram/`.
- engram-cloud otros estados → `not_enrolled`: `engram cloud enroll <project>`. `auth`: exportá un `ENGRAM_CLOUD_TOKEN` válido en `~/.zshenv` (NO `~/.zshrc` — los hooks corren en shell no-interactivo y zsh no carga `~/.zshrc` ahí; un token en `~/.zshrc` nunca llega al hook y produce este `auth`/401). `forbidden`: pedí acceso al proyecto en el server. `unreachable`: verificá que el server esté arriba / tu red. `cli_no_cloud`: actualizá el binario engram (tu versión no tiene el subcomando `cloud`).
- `.forja.json` ausente → `/forja:init` en un directorio nuevo, o crearlo a mano si el proyecto ya existe.
- sin comando `check` → declarar `commands.check` en `.forja.json` (contrato: `wiki/rules/contrato-forja.md`; fallback v1 `pnpm run check`).
- settings sin marketplace → agregar `extraKnownMarketplaces`/`enabledPlugins` de forja a `.claude/settings.json`.
- falta develop → `git branch develop && git push -u origin develop`.
- `forja.devUser` sin setear → capturá primero y seteá solo si no está vacío: `L="$(gh api user -q .login 2>/dev/null | tr '[:upper:]' '[:lower:]')"; [ -n "$L" ] && git config --local forja.devUser "$L"` — define el hostname de TU preview (solo minúsculas, dígitos y guiones).
- requerimientos sin `openspec/` → si el SDD ya arrancó, el artifact store quedó en engram por error: re-corré `sdd-init` eligiendo `openspec` (doctrina del equipo) para que los artefactos viajen en los PRs.
- LSP ausente (opcional) → `npm install -g bash-language-server dockerfile-language-server-nodejs yaml-language-server`, y para los diagnósticos de bash `brew install shellcheck shfmt`. forja ya trae la config LSP (`.lsp.json`, bash/docker/yaml); solo faltan los binarios en el PATH. Los language servers del stack de la app (TypeScript, Go, etc.) los define cada proyecto.

Cerrá con un veredicto de una línea: "listo para trabajar" o "arreglá X antes de seguir".

Si durante el diagnóstico detectás que un flujo del propio plugin forja falló (un script que no debería fallar, un hook degradado, un comando que abortó), ofrecé reportarlo con la skill `report-failure`: junta el diagnóstico real (versión de Claude Code, SO, versión del plugin), redacta datos sensibles y abre el issue SOLO con confirmación del usuario. Es el canal de mejora continua del plugin; nunca lo dispares automáticamente.
