---
description: Bootstrap de un proyecto nuevo con la doctrina forja - preflight, esqueleto ejecutable, Gitflow y settings de equipo
argument-hint: "[--force]"
disable-model-invocation: true
---

# /forja:init $ARGUMENTS

Montás un proyecto nuevo desde cero con la doctrina forja: preflight de herramientas, esqueleto ejecutable instanciado desde los templates del plugin, Gitflow (main/develop) y settings de equipo. Doctrina: skill `forja:doctrina`, receta `arrancar-proyecto`.

## Modos de fallo (leelos ANTES de arrancar)

- **Directorio no vacío** → ABORTAR y explicar, salvo que el usuario haya pasado `--force` (solo `.git` y `.DS_Store` se toleran). Con `--force`, el instanciador pisa lo que haya.
- **Herramienta dura faltante** → mostrar la tabla de preflight y ABORTAR con instrucciones de instalación. No improvises workarounds.
- **`pnpm run check` rojo** → NO es un fallo terminal: es un loop de arreglo. Arreglás el gate que falla y re-corrés hasta verde. JAMÁS declares el bootstrap exitoso con el check rojo.

## Paso 1 — Preflight

Corré TODO el preflight en UN solo bloque de bash y después mostrá una tabla PASS/WARN/FAIL. Abortá solo ante fallos duros.

```bash
echo "== git (HARD) =="; git --version || echo "PREFLIGHT_FAIL git"
echo "== node (HARD) =="; node -v || echo "PREFLIGHT_FAIL node"
echo "== pnpm (HARD) =="; pnpm -v || corepack enable pnpm || echo "PREFLIGHT_FAIL pnpm"
echo "== gh (HARD si va a crear repo en GitHub) =="; gh --version && gh auth status || echo "PREFLIGHT_WARN gh"
echo "== docker (WARN) =="; docker version --format '{{.Server.Version}}' || echo "PREFLIGHT_WARN docker"
echo "== gentle-ai (WARN) =="; command -v gentle-ai || echo "PREFLIGHT_WARN gentle-ai"
echo "== engram (WARN) =="; claude mcp list 2>/dev/null | grep -qi engram && echo "engram OK" || echo "PREFLIGHT_WARN engram"
```

Interpretación:

- `git`, `node`, `pnpm` → **duros**: sin eso no hay proyecto. Abortá con el comando de instalación.
- `gh` → duro SOLO si el usuario quiere crear el repo en GitHub desde acá; si no, WARN + dejá los pasos manuales al final. Ojo: si `gh auth status` muestra **dos cuentas**, verificá que la activa sea la correcta para la org destino — avisá si no lo es.
- `docker` → WARN: hace falta para testcontainers y para `/forja:deploy preview`.
- `gentle-ai` → WARN: "instalá gentle-ai antes de `/sdd-init`".
- `engram` → WARN: memoria persistente del agente; sin eso el proceso funciona pero pierde continuidad.

## Paso 2 — Preguntas

Usá AskUserQuestion para juntar los datos del proyecto. Validá los formatos ANTES de seguir; si algo no valida, repreguntá.

| Dato | Validación | Default |
| --- | --- | --- |
| PROJECT_NAME | texto libre (nombre humano) | — |
| APP (slug interno) | `[a-z][a-z0-9_]*` | — |
| PUBLIC_NAME | DNS label: `[a-z0-9-]`, sin `_` | APP con `_` → `-` |
| DOMAIN | dominio válido | — |
| GH_ORG / GH_REPO | org/repo de GitHub + ¿privado? | privado: sí |
| NODE_VERSION | entero | 22 |
| PG_MAJOR | entero | 17 — recordá: "la mayor de Postgres se fija ANTES de crear el volumen de prod; cambiarla después es migración" |
| DB_USER | slug | `app` |
| DB_NAME | slug | = APP |

Mostrá la tabla resumen con todos los valores y pedí confirmación explícita antes de tocar el disco.

## Paso 3 — Instanciar el esqueleto

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/forja-instantiate.sh" "$PWD" \
  APP=<app> PUBLIC_NAME=<public-name> DOMAIN=<domain> \
  GH_ORG=<org> GH_REPO=<repo> NODE_VERSION=<node> PG_MAJOR=<pg> \
  DB_USER=<db-user> DB_NAME=<db-name> PROJECT_NAME="<nombre humano>"
```

- Si el usuario pasó `--force`, anteponé `FORCE=1` como variable de entorno.
- Si el script falla, mostrá su error **verbatim** — el script es determinista y su mensaje dice exactamente qué pasó. No lo parafrasees ni improvises un arreglo alternativo.

## Paso 4 — Git + Gitflow

En orden, sin saltear:

1. `git init -b main`
2. `pnpm install`
3. `pnpm run check` — **tiene que salir verde**. Si sale rojo: leé el gate que falló, arreglalo y re-corré. Repetí hasta verde. NUNCA declares éxito con el check rojo.
4. `git add -A && git commit -m "chore: bootstrap project skeleton with forja"` — mensaje en inglés, Conventional Commits, SIN atribución de IA.
5. `git branch develop && git checkout develop`

## Paso 5 — GitHub (preguntale al usuario primero)

Si el usuario quiere el repo en GitHub y `gh` está autenticado con la cuenta correcta:

```bash
gh repo create <org>/<repo> --private --source . --push
git push -u origin develop
gh repo edit <org>/<repo> --default-branch develop
```

Nota para el usuario: en plan free de GitHub no hay branch protection en repos privados — el candado real de production es el preflight de `/forja:deploy` (rama, tree limpio, tags), no una regla del server.

## Paso 6 — Cierre

Mostrá un resumen de lo creado y los próximos pasos:

1. Decime **"entrevistame"** → la skill `spec-doc-interviewer` arma la documentación base en `software_requirements/`.
2. Diseño visual: carpeta `claude_design/` con [claude.ai/design](https://claude.ai/design).
3. Corré **`/sdd-init`** de gentle-ai (artifact store: `openspec`) para activar el flujo SDD.
4. Infra cuando toque: carpeta `ops/` + el wrapper `hcloud-agent.sh` del plugin (`/forja:doctor` muestra su ruta exacta) + skill `forja:doctrina`, receta `operar-servidor`.
5. Primer deploy: **`/forja:deploy preview`**.
