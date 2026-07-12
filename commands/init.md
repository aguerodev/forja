---
description: Adoptar un proyecto existente (o arrancar uno nuevo) con la capa forja - contrato .forja.json, scripts de release, Gitflow y settings de equipo
argument-hint: "[--force]"
disable-model-invocation: true
---

# /forja:init $ARGUMENTS

Instalás la **capa agnóstica de forja** sobre un proyecto: el contrato `.forja.json`, los scripts de release, `deploy.sh`, `stack.yml`, la carpeta `ops/`, el `CLAUDE.md` ancla y los settings de equipo. **forja no toca el código de la app, jamás**: el stack (lenguaje, framework, Dockerfile) es del proyecto; forja aporta proceso y operación. Doctrina: skill `forja:doctrina`, receta `arrancar-proyecto`; el contrato está especificado en `wiki/rules/contrato-forja.md`.

## Los dos modos

| Modo | Cuándo | Qué hace |
| --- | --- | --- |
| **adopt** (default) | El cwd es un repo git con contenido | Instala SOLO la capa agnóstica. Un archivo que ya existe se **omite** y se reporta como colisión — nunca se pisa nada |
| **new** | Directorio vacío (solo `.git`/`.DS_Store` se toleran) | Misma capa agnóstica + `git init` y Gitflow; el código de la app lo traés después |

`--force` aplica SOLO al modo new: re-estampa un directorio no vacío **pisando** lo que haya (destructivo — pedí confirmación explícita antes de usarlo). En adopt no existe forzar: adoptar nunca sobreescribe.

## Modos de fallo (leelos ANTES de arrancar)

- **Ya hay `.forja.json`** → el proyecto ya está inicializado: ABORTAR y derivar a `/forja:doctor` (diagnóstico y remediaciones). No re-inicialices.
- **Herramienta dura faltante** → mostrar la tabla de preflight y ABORTAR con instrucciones de instalación. No improvises workarounds.
- **Directorio ambiguo** (hay archivos pero no es repo git) → PREGUNTAR: ¿corremos `git init` y lo adoptamos, o abortamos? Nunca decidas solo.
- **Colisiones en adopt** → NO son fallos: el instanciador las omite y las lista; van al reporte final.

## Paso 1 — Preflight

Corré TODO el preflight en UN solo bloque de bash y después mostrá una tabla PASS/WARN/FAIL. Abortá solo ante fallos duros. No hay preflight del toolchain del stack: eso lo declara el contrato y se valida en el Paso 6.

```bash
echo "== git (HARD) =="; git --version || echo "PREFLIGHT_FAIL git"
echo "== node (HARD, runtime del tooling forja) =="; node -v || echo "PREFLIGHT_FAIL node"
echo "== gh (HARD si va a crear repo en GitHub) =="; gh --version && gh auth status || echo "PREFLIGHT_WARN gh"
echo "== docker (WARN) =="; docker version --format '{{.Server.Version}}' || echo "PREFLIGHT_WARN docker"
echo "== gentle-ai (WARN) =="; command -v gentle-ai || echo "PREFLIGHT_WARN gentle-ai"
echo "== engram MCP (WARN) =="; claude mcp list 2>/dev/null | grep -qi engram && echo "engram MCP OK" || echo "PREFLIGHT_WARN engram-mcp"
echo "== engram CLI (WARN) =="; command -v engram || echo "PREFLIGHT_WARN engram-cli"
```

Interpretación:

- `git`, `node` → **duros**: sin eso no hay proyecto (node es el runtime del tooling forja — hooks y scripts parsean JSON con node —, no una opinión sobre el stack de la app).
- `gh` → duro SOLO si el usuario quiere crear el repo en GitHub desde acá; si no, WARN + dejá los pasos manuales al final. Ojo: si `gh auth status` muestra **dos cuentas**, verificá que la activa sea la correcta para la org destino — avisá si no lo es.
- `docker` → WARN: hace falta para `/forja:deploy preview` y los tests de integración del proyecto.
- `gentle-ai` → WARN: "instalá gentle-ai antes de `/sdd-init`".
- `engram` MCP → WARN: memoria persistente del agente; sin eso el proceso funciona pero pierde continuidad.
- `engram` CLI → WARN: sin el binario no hay **memoria de equipo** (git sync) — el MCP y el CLI son piezas distintas; el template ya deja `.engram/config.json` listo para cuando esté.

## Paso 2 — Detección de modo

```bash
echo "== forja =="; test -f .forja.json && echo "YA_INICIALIZADO" || echo "sin .forja.json"
echo "== git =="; git rev-parse --is-inside-work-tree 2>/dev/null || echo "NO_GIT"
echo "== contenido =="; ls -A | grep -vE '^(\.git|\.DS_Store)$' | head -20
```

| Resultado | Modo |
| --- | --- |
| `.forja.json` existe | **ABORTAR** → "este proyecto ya está inicializado; corré `/forja:doctor`" |
| Repo git + archivos | **adopt** |
| Vacío (con o sin `.git`) | **new** |
| Archivos pero NO repo git | **PREGUNTAR**: ¿`git init` + adopt, o abortar? |

Anunciá el modo detectado antes de seguir: "voy a **adoptar** este proyecto" / "voy a **crear** uno nuevo".

## Paso 3 — Sniffing del stack (solo adopt)

Oleé el repo para PREFILL de los comandos del contrato. Los prefills son **propuestas**: el usuario confirma cada valor en el Paso 4 — nunca los des por buenos en silencio.

| Si existe | Proponé |
| --- | --- |
| `package.json` con `scripts` | Variantes `<pm> run <script>` con el package manager según lockfile (`pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn, `package-lock.json` → npm); version: `node -p "require('./package.json').version"` |
| `Makefile` | Los targets que EXISTAN en el archivo (`make check`, `make test`, `make build` — verificalos con grep, no los inventes) |
| `go.mod` | install: `go mod download`; check: `go vet ./... && go build ./...`; test: `go test ./...`; version: sugerí que el operador la defina (`git describe --tags` o un archivo `VERSION` con `cat VERSION`) |
| `pyproject.toml` | Variantes `uv run ...` o `poetry run ...` según lockfile (`uv.lock` / `poetry.lock`) |
| `Cargo.toml` | check: `cargo check`; test: `cargo test`; version: `cargo pkgid` (la parte tras `#`) o un archivo `VERSION` |
| Nada matchea | Preguntá todo con defaults vacíos, apuntando a `wiki/rules/contrato-forja.md` para el significado de cada comando |

Para el runtime: si hay un `Dockerfile` con `EXPOSE`, proponé ese puerto como `APP_PORT`; un endpoint de health existente en el código (buscá `/health`, `/healthz`, `/api/health`) como `HEALTH_PATH`.

## Paso 4 — Preguntas

Usá AskUserQuestion para juntar los datos. En adopt, PREFILL de identidad desde el repo: `PROJECT_NAME` del name del `package.json`/`pyproject.toml` o del nombre del directorio; `APP` = slug de ese nombre; `GH_ORG`/`GH_REPO` de `git remote get-url origin` si existe. Validá los formatos ANTES de seguir; si algo no valida, repreguntá.

| Dato | Validación | Default / prefill |
| --- | --- | --- |
| PROJECT_NAME | texto libre (nombre humano) | nombre del package o del directorio |
| APP (slug interno) | `[a-z][a-z0-9_]*` | slug del nombre |
| PUBLIC_NAME | DNS label: `[a-z0-9-]`, sin `_` | APP con `_` → `-` |
| DOMAIN | dominio válido | — |
| GH_ORG / GH_REPO | org/repo de GitHub + ¿privado? | del remote `origin` si existe; privado: sí |
| PG_MAJOR | entero | 17 — recordá: "la mayor de Postgres se fija ANTES de crear el volumen de prod; cambiarla después es migración" |
| DB_USER | slug | `app` |
| DB_NAME | slug | = APP |
| CMD_INSTALL | comando shell | del sniffing (Paso 3) |
| CMD_CHECK | comando shell (EL gate: local = CI) | del sniffing |
| CMD_TEST | comando shell (tests unit, sin I/O) | del sniffing |
| CMD_VERSION | comando shell (imprime la versión en stdout) | del sniffing — pasá el comando TAL CUAL, con sus comillas: el instanciador lo escapa al escribir `.forja.json` |
| APP_PORT | entero (puerto interno del contenedor) | del Dockerfile si existe; 8000 |
| HEALTH_PATH | `/` seguido de `[A-Za-z0-9/._-]` | del código si existe; `/api/health` |

Mostrá la tabla resumen con todos los valores y pedí confirmación explícita antes de tocar el disco.

## Paso 5 — Instalar la capa agnóstica

```bash
# adopt (default en repo con contenido):
ADOPT=1 bash "${CLAUDE_PLUGIN_ROOT}/scripts/forja-instantiate.sh" "$PWD" \
  APP=<app> PUBLIC_NAME=<public-name> DOMAIN=<domain> \
  GH_ORG=<org> GH_REPO=<repo> PG_MAJOR=<pg> \
  DB_USER=<db-user> DB_NAME=<db-name> PROJECT_NAME="<nombre humano>" \
  CMD_INSTALL="<cmd>" CMD_CHECK="<cmd>" CMD_TEST="<cmd>" CMD_VERSION="<cmd>" \
  APP_PORT=<puerto> HEALTH_PATH=<path>

# new (directorio vacío): el mismo comando SIN ADOPT=1.
# new + --force del usuario: anteponé FORCE=1 (destructivo, confirmación previa).
```

- El instanciador **nunca pisa archivos en adopt**: lo que ya existía queda listado como "kept existing files", y al final imprime una línea `installed: <path>` por cada archivo que SÍ escribió. Guardate las dos listas: la de `installed:` alimenta el staging del Paso 6; la de colisiones, el reporte del Paso 7.
- Si el script falla, mostrá su error **verbatim** — es determinista y su mensaje dice exactamente qué pasó (p. ej. `.forja.json` ya existente = proyecto ya inicializado). No lo parafrasees ni improvises un arreglo alternativo.
- Colisiones típicas en adopt y qué sugerir con cada una (van al reporte del Paso 7):
  - `CLAUDE.md` / `README.md` ya existían → integrar a mano el bloque forja (doctrina, gates, contrato) en los del proyecto.
  - `.claude/settings.json` ya existía → verificar que referencie el marketplace forja (`/forja:doctor` lo chequea).
  - `.engram/config.json` ya existía → verificar que su `project_name` == `APP` (si difieren, la memoria de equipo se fragmenta).
  - `.gitignore` ya existía → asegurar que cubra `secrets/*.env`, `.env`, `backups/` y `.engram/engram.db*`.

## Paso 6 — Git, Gitflow y GitHub

**En new** (sin saltear):

1. Si NO existe `.git`: `git init -b main`. Si ya existe (repo vacío): verificá la rama default con `git symbolic-ref --short HEAD` y, si no es `main`, renombrala explícitamente (`git branch -m <actual> main`) antes de seguir con Gitflow.
2. `git add -A && git commit -m "chore: bootstrap forja project layer"` — mensaje en inglés, Conventional Commits, SIN atribución de IA (en new el directorio era vacío: todo lo que hay lo escribió forja).
3. `git branch develop && git checkout develop`
4. El template no trae código de app: **no hay check que correr todavía** — decilo explícitamente; el gate `CMD_CHECK` aplica desde que exista el código de la app.

**En adopt** (respetá lo que ya hay):

1. Stageá **EXACTAMENTE los paths que el instanciador imprimió como `installed:`** — uno por uno, archivo por archivo (`git add <path> <path> ...` con esa lista literal). PROHIBIDO usar globs de directorio (`git add scripts/`, `git add ops/` y sobre todo `git add secrets/`): en un repo adoptado esos globs arrastran archivos propios del proyecto, y `secrets/` puede arrastrar valores reales si el `.gitignore` del proyecto quedó como colisión sin los patrones de forja. NUNCA `git add -A` sobre un repo ajeno. Con la lista stageada, proponé el commit `chore: adopt forja project layer` — confirmación antes de commitear.
2. Ramas: NO toques la rama default. Si no existe `develop`, proponé crearla (Gitflow del equipo: `main` producción, `develop` integración) — solo con confirmación del usuario.
3. **Validación del contrato (recomendada)**: corré el `CMD_CHECK` confirmado — verde valida que el contrato apunta a comandos reales; rojo NO bloquea la adopción, pero reportalo y sugerí corregir el valor (o el proyecto) antes del primer PR.

**GitHub** (solo new, o adopt sin remote — preguntale al usuario primero). Si quiere el repo en GitHub y `gh` está autenticado con la cuenta correcta:

```bash
gh repo create <org>/<repo> --private --source . --push
git push -u origin develop
gh repo edit <org>/<repo> --default-branch develop
```

**Label de preview por developer** (todos los modos, si hay `gh` autenticado):

```bash
DEV_LOGIN="$(gh api user -q .login 2>/dev/null | tr '[:upper:]' '[:lower:]')"
[ -n "$DEV_LOGIN" ] && git config --local forja.devUser "$DEV_LOGIN" || echo "WARN: no pude obtener el login de gh - forja.devUser queda sin setear (NO lo setees vacío)"
```

Tu preview vivirá en `<usuario>-<publicName>.<dominio>` y no colisiona con el de tus compañeros (cada uno tiene su Swarm local y su túnel). Sin GitHub, no la corras — el fallback `dev-` es correcto para un solo developer. Cada compañero que clone el repo la corre una vez (`/forja:doctor` avisa si falta).

Nota para el usuario: en plan free de GitHub no hay branch protection en repos privados — el candado real de production es el preflight de `/forja:deploy` (rama, tree limpio, tags), no una regla del server.

## Paso 7 — Cierre y reporte

Mostrá un reporte con CUATRO bloques:

1. **Instalado**: los archivos que forja escribió (contrato, scripts de release, `deploy.sh`, `stack.yml`, `ops/`, settings).
2. **Omitido (colisiones)**: los archivos que ya existían y quedaron intactos, con la acción sugerida de cada uno (Paso 5).
3. **Gap del contrato de imagen** — SOLO si el proyecto no tiene `Dockerfile`: `/forja:deploy` lo necesita y forja NO lo genera. Imprimí el resumen del contrato (doctrina `forja:doctrina`, wiki ops/02): targets `runner` / `migrator` / `backup`; el `runner` escucha en `APP_PORT` y trae un comando de sonda (`wget`, `curl` o el runtime del stack — o definí `runtime.healthcheckExec`); usuario sin privilegios; instalación congelada al lockfile.
4. **Próximos pasos**:
   1. Decime **"entrevistame"** → la skill `spec-doc-interviewer` arma la documentación base en `software_requirements/`.
   2. Diseño visual: carpeta `claude_design/` con [claude.ai/design](https://claude.ai/design).
   3. Corré **`/sdd-init`** de gentle-ai (artifact store: `openspec`) para activar el flujo SDD.
   4. Infra cuando toque: carpeta `ops/` + el wrapper `hcloud-agent.sh` del plugin (`/forja:doctor` muestra su ruta exacta) + skill `forja:doctrina`, receta `operar-servidor`.
   5. Primer deploy: **`/forja:deploy preview`** — requiere el `Dockerfile` del punto 3.
   6. **Memoria de equipo**: al cerrar cada unidad de trabajo, `engram sync` + commitear `.engram/` junto con el código; al arrancar sesión el hook importa solo. El detalle vive en el CLAUDE.md del proyecto («Memoria de equipo (engram)»).
