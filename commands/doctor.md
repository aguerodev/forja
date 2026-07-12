---
description: Diagnóstico forja - verificar herramientas, preflight de entorno y conformidad del proyecto con el contrato. Check forja setup, verify tools, environment diagnosis.
---

# /forja:doctor

Diagnóstico de solo-lectura en DOS capas: la **capa genérica** (herramientas y conformidad que aplican a todo proyecto) y la **capa de contrato** (los `commands.*` y el `runtime` de `.forja.json`, o sus fallbacks v1). **NUNCA modifiques nada** — este comando diagnostica y recomienda; arreglar es decisión del usuario.

## Capa genérica

### Paso 1 — Herramientas

Corré todo en UN bloque de bash:

```bash
echo "== git =="; git --version || echo "DOCTOR_FAIL git"
echo "== node (runtime del tooling forja) =="; node -v || echo "DOCTOR_FAIL node (los hooks y scripts de forja parsean JSON con node - es el runtime del tooling, no una opinión sobre el stack de la app)"
echo "== gh =="; gh --version && gh auth status || echo "DOCTOR_WARN gh"
echo "== docker =="; docker version --format '{{.Server.Version}}' || echo "DOCTOR_WARN docker"
echo "== gentle-ai =="; command -v gentle-ai || echo "DOCTOR_WARN gentle-ai"
echo "== engram MCP =="; claude mcp list 2>/dev/null | grep -qi engram && echo "engram MCP OK" || echo "DOCTOR_WARN engram-mcp"
echo "== engram CLI =="; command -v engram || echo "DOCTOR_WARN engram-cli (sin binario no hay memoria de equipo)"
echo "== hcloud (opcional, solo infra) =="; command -v hcloud || echo "DOCTOR_INFO hcloud ausente"
echo "== wrapper infra =="; ls "${CLAUDE_PLUGIN_ROOT}/bin/hcloud-agent.sh" 2>/dev/null || echo "DOCTOR_INFO wrapper en el bin/ del plugin forja"
echo "== LSP servers (opcional; los que configura el .lsp.json del plugin) =="
node -p 'Object.values(JSON.parse(require("fs").readFileSync(process.env.CLAUDE_PLUGIN_ROOT + "/.lsp.json","utf8"))).map(function(s){return s.command}).join("\n")' 2>/dev/null | while IFS= read -r s; do
  [ -n "$s" ] || continue
  command -v "$s" >/dev/null 2>&1 && echo "  $s OK" || echo "DOCTOR_INFO lsp $s ausente"
done
echo "== shellcheck/shfmt (opcional, diagnósticos del LSP de bash) =="
for s in shellcheck shfmt; do
  command -v "$s" >/dev/null 2>&1 && echo "  $s OK" || echo "DOCTOR_INFO lsp-bash $s ausente"
done
```

La línea del wrapper imprime la **ruta exacta** de `hcloud-agent.sh` — esa es la que se usa para operar infra (nunca `hcloud` crudo; la guardia del plugin lo bloquea). El toolchain del stack de la app NO se chequea acá: eso lo hace la capa de contrato, comando por comando.

### Paso 2 — Conformidad del proyecto (solo si estás parado en un proyecto)

Si el directorio actual es un repo git con intención de ser proyecto forja, verificá:

```bash
echo "== .forja.json (existencia, parseo y forma) =="
node -e '
const fs = require("fs");
let c;
try { c = JSON.parse(fs.readFileSync(".forja.json", "utf8")); }
catch (e) { console.log("DOCTOR_FAIL .forja.json ausente o invalido: " + e.message); process.exit(0); }
if (!c.app) console.log("DOCTOR_FAIL .forja.json sin campo app");
else console.log("app: " + c.app);
const v2 = !!(c.commands || c.runtime);
console.log(v2 ? "shape: v2 (commands/runtime presentes)" : "DOCTOR_WARN shape: v1 (sin commands/runtime - operan los fallbacks; ver migracion abajo)");
'
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

### Migración v1 → v2 (solo si la forma detectada fue v1)

Si `.forja.json` es v1, generá un bloque v2 **listo para pegar** construido con los valores reales del archivo + los defaults documentados (`wiki/rules/contrato-forja.md`) — los defaults reproducen exactamente el comportamiento v1, así que la migración es segura por construcción:

```bash
node -e '
const c = JSON.parse(require("fs").readFileSync(".forja.json","utf8"));
if (c.commands || c.runtime) { console.log("ya es v2 - nada que migrar"); process.exit(0); }
const v2 = { ...c };
delete v2.nodeVersion; // v1-only: el stack lo describe el contrato, no un campo suelto
v2.commands = {
  install: "pnpm install",
  check: "pnpm run check",
  test: "pnpm test:unit",
  version: "node -p \"require(\x27./package.json\x27).version\"",
};
v2.runtime = { port: 8000, healthcheckPath: "/api/health" };
console.log(JSON.stringify(v2, null, 2));
'
```

Mostrá el bloque emitido y decile al usuario que ES el contenido sugerido para reemplazar su `.forja.json` (ajustando los comandos si su stack no es el default pnpm). **JAMÁS edites el archivo vos**: la migración del contrato la hace el usuario.

## Capa de contrato (v2 o fallbacks v1)

Solo con un `.forja.json` legible. Cada comando efectivo (declarado, o su fallback v1 documentado) se verifica de forma barata: ¿la **primera palabra** del comando resuelve como binario en el PATH?

```bash
echo "== contrato: comandos =="
node -e '
const c = JSON.parse(require("fs").readFileSync(".forja.json","utf8"));
const cmds = c.commands || {};
const eff = {
  check: cmds.check || "pnpm run check",
  test: cmds.test || "pnpm test:unit",
  version: cmds.version || "node -p \"require(\x27./package.json\x27).version\"",
};
if (cmds.install) eff.install = cmds.install;
for (const k of Object.keys(eff)) console.log(k + "\t" + eff[k]);
' | while IFS="$(printf '\t')" read -r name cmd; do
  bin="${cmd%% *}"
  if command -v "$bin" >/dev/null 2>&1; then
    echo "  [OK] commands.$name = $cmd"
  else
    echo "  DOCTOR_WARN commands.$name = \"$cmd\" (el binario '$bin' no esta en el PATH - instala el toolchain o corregi el comando)"
  fi
done
echo "== contrato: runtime =="
node -e '
const c = JSON.parse(require("fs").readFileSync(".forja.json","utf8"));
const rt = c.runtime || {};
const port = rt.port != null ? rt.port : 8000;
const hp = rt.healthcheckPath || "/api/health";
console.log(/^[0-9]+$/.test(String(port)) ? "  [OK] runtime.port = " + port : "  DOCTOR_FAIL runtime.port no numerico: " + port);
console.log(/^\/[A-Za-z0-9\/._-]*$/.test(hp) ? "  [OK] runtime.healthcheckPath = " + hp : "  DOCTOR_FAIL runtime.healthcheckPath mal formado: " + hp);
'
echo "== contrato: imagen =="
if [ -f Dockerfile ]; then
  echo "  [OK] Dockerfile presente"
else
  echo "  DOCTOR_WARN sin Dockerfile - /forja:deploy lo necesita y forja NO lo genera. Contrato de imagen (doctrina wiki ops/02): targets runner/migrator/backup; el runner escucha en runtime.port y trae un comando de sonda (wget, curl o el runtime del stack - o defini runtime.healthcheckExec); usuario sin privilegios; instalacion congelada al lockfile."
fi
```

## Paso 3 — Reporte

Mostrá una tabla única: fila por chequeo, columna estado (PASS/WARN/FAIL) y columna **remediación** con el paso concreto:

- git/node faltantes → comando de instalación (node es el runtime del tooling forja, no una opinión sobre el stack de la app).
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
- `.forja.json` ausente → `/forja:init` (adopta un proyecto existente o arranca uno nuevo).
- `.forja.json` con forma v1 → migrarlo a v2 pegando el bloque sugerido de arriba (ajustar los comandos al stack real; contrato: `wiki/rules/contrato-forja.md`). Los defaults del bloque reproducen el comportamiento v1 tal cual.
- `commands.*` con binario ausente → instalar el toolchain del stack en esta máquina, o corregir el comando en `.forja.json` para que apunte al toolchain real del proyecto.
- `runtime.port` / `runtime.healthcheckPath` mal formados → corregirlos en `.forja.json` (puerto numérico; path que empieza con `/`, sin espacios ni comillas).
- sin `Dockerfile` → el proyecto lo aporta cumpliendo el contrato de imagen (doctrina `forja:doctrina`, wiki ops/02) antes del primer `/forja:deploy`.
- settings sin marketplace → agregar `extraKnownMarketplaces`/`enabledPlugins` de forja a `.claude/settings.json`.
- falta develop → `git branch develop && git push -u origin develop`.
- `forja.devUser` sin setear → capturá primero y seteá solo si no está vacío: `L="$(gh api user -q .login 2>/dev/null | tr '[:upper:]' '[:lower:]')"; [ -n "$L" ] && git config --local forja.devUser "$L"` — define el hostname de TU preview (solo minúsculas, dígitos y guiones).
- requerimientos sin `openspec/` → si el SDD ya arrancó, el artifact store quedó en engram por error: re-corré `sdd-init` eligiendo `openspec` (doctrina del equipo) para que los artefactos viajen en los PRs.
- LSP ausente (opcional) → instalar los binarios que declara el `.lsp.json` del plugin (hoy: `npm install -g bash-language-server dockerfile-language-server-nodejs yaml-language-server`) y, para los diagnósticos de bash, `brew install shellcheck shfmt`. Los language servers del stack de la app los define cada proyecto.

Cerrá con un veredicto de una línea: "listo para trabajar" o "arreglá X antes de seguir".

Si durante el diagnóstico detectás que un flujo del propio plugin forja falló (un script que no debería fallar, un hook degradado, un comando que abortó), ofrecé reportarlo con la skill `report-failure`: junta el diagnóstico real (versión de Claude Code, SO, versión del plugin), redacta datos sensibles y abre el issue SOLO con confirmación del usuario. Es el canal de mejora continua del plugin; nunca lo dispares automáticamente.
