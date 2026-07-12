# CLAUDE.md — {{PROJECT_NAME}}

Doctrina de ingeniería de la agencia: arquitectura, proceso y operaciones para construir software de calidad. La fuente de verdad es el **plugin forja** (doctrina + comandos + guardias); este archivo es el ancla del proyecto: contexto propio + las reglas que gobiernan todo. Si el código contradice una regla, se corrige el código o se actualiza la regla — nunca se ignora en silencio.

## Contexto del proyecto

| Campo | Valor |
| --- | --- |
| Aplicación (`APP`) | `{{APP}}` |
| Repositorio | `{{GH_ORG}}/{{GH_REPO}}` |
| Dominio de producción | `{{PUBLIC_NAME}}.{{DOMAIN}}` |
| Dominio de preview (Swarm local, POR developer) | `<tu-usuario>-{{PUBLIC_NAME}}.{{DOMAIN}}` — el label sale de `git config forja.devUser` (fallback `dev-` para un solo dev) |
| Contexto Docker de prod | `{{APP}}-prod` |
| Gate de calidad (`commands.check`) | `{{CMD_CHECK}}` |
| Tests unit (`commands.test`) | `{{CMD_TEST}}` |
| Puerto interno / health (`runtime`) | `{{APP_PORT}}` · `{{HEALTH_PATH}}` |
| PostgreSQL | `{{PG_MAJOR}}` |

> La copia machine-readable de este contexto vive en `.forja.json` (la leen los comandos del plugin y los hooks). Si cambiás un valor acá, actualizá `.forja.json` en el mismo commit — mantenelas en sincronía.

## El plugin forja

- **La doctrina se carga por el skill `forja:doctrina`**, que trae el MANIFIESTO con el índice por tiers y **recetas por tarea** (`nueva-feature`, `desplegar`, `rollback`, `operar-servidor`, `arrancar-proyecto`, `onboarding-secretos`). Cargá la receta de tu tarea; **NO leas la wiki entera**.
- **Comandos del operador**: `/forja:deploy` (release a prod), `/forja:rollback` (dos planos: software barato, datos destructivo y human-confirmed), `/forja:status` (estado del stack y del trabajo), `/forja:doctor` (diagnóstico del entorno).
- **Guardias activas** (hooks del plugin, no opcionales):
  - Push/commit directo a `main` o `develop` **bloqueado** — todo entra por PR.
  - Atribución de IA en commits **bloqueada** (sin `Co-Authored-By`, sin "Generated with").
  - `hcloud` crudo **bloqueado** — la infraestructura se gestiona vía el wrapper `hcloud-agent.sh` del plugin (`/forja:doctor` muestra su ruta), con token read por defecto y break-glass humano para mutaciones.

## Flujo: de la idea al deploy

| Paso | Qué |
| --- | --- |
| **0. Requerimientos** | Correr la entrevista `spec-doc-interviewer` → genera los documentos en `software_requirements/` |
| **1. SDD** | gentle-ai sobre los requerimientos: propose → spec → design → tasks → apply → verify (artifact store `openspec`) |
| **2. Código** | Hexagonal + vertical slices + **TDD estricto** (el test rojo va primero); dominio puro |
| **3. Dev** | Correr y **probar en dev** hasta que la versión esté lista para usar |
| **4. Deploy** | Una vez probada en dev → `/forja:deploy` |

## Política de ramas (Gitflow) — `main` es PRODUCCIÓN

- **`main` = producción, protegida.** Lo que vive en `main` es lo que corre (o va a correr) en `{{PUBLIC_NAME}}.{{DOMAIN}}`. **NUNCA** se commitea ni se pushea directo.
- **`develop` = rama default.** Integración continua del equipo; tampoco recibe push directo.
- **`feature/*`** nace de `develop` y vuelve por PR. **`release/*`** prepara el corte: el **bump de versión se hace SOLO en `release/*`**. **`hotfix/*`** nace de `main` para el incendio.
- **Back-merge obligatorio**: todo lo que entra a `main` (release u hotfix) vuelve a `develop`.
- Ningún PR se mergea sin el `check` del contrato (`{{CMD_CHECK}}`) **verde**. Y ningún PR se abre sin **`engram sync` + commit de `.engram/`**: el código y el conocimiento que lo produjo viajan en el MISMO PR (es un paso del protocolo, no un opcional).
- **Enforcement en tres capas**: la convención del equipo + la guardia del plugin (bloquea push/commit directo a `main`/`develop` en local) + el **preflight de `/forja:deploy`** (nada llega a prod si no es `main`, limpio, al día y con gates verdes). Si el plan de GitHub no ofrece branch protection, el candado real es ese preflight.

## Preferencias de proceso (gentle-ai / SDD)

- **Artifact store: `openspec`.** Los artefactos SDD (proposal, spec, design, tasks) viven como archivos en `openspec/` — committeables, con historial git, compartibles con el equipo. **NO usar engram como store de artefactos SDD.**
- **Engram SIEMPRE activo.** Guardá decisiones, bugs con causa raíz, convenciones y descubrimientos proactivamente — y compartilos con el equipo vía git sync (ver «Memoria de equipo»).
- **Modo de ejecución: AUTOMÁTICO (`auto-chain`).** Encadená las fases SDD sin pausar; el gatekeeper valida cada fase antes de la siguiente. No pares hasta tener la versión lista para probar en dev — interrumpí solo ante un bloqueo real o una decisión de negocio que no podés resolver.
- **TDD estricto.** El test rojo va primero; el runner es el comando `test` del contrato (`{{CMD_TEST}}`, sin I/O).

## Memoria de equipo (engram)

- **La memoria de engram es del PROYECTO y viaja por git.** `.engram/manifest.json` + `.engram/chunks/` se commitean; la DB local (`.engram/engram.db`) está gitignoreada. Los chunks son content-hashed e inmutables — dos devs exportan en paralelo sin pisarse. El ÚNICO archivo que puede conflictuar en un merge es `manifest.json`: se resuelve con la **unión de ambas listas de chunks**, JAMÁS con "ours"/"theirs" — el import se guía solo por el manifest, así que descartar una entrada borra memoria del equipo en silencio.
- **Al arrancar la sesión** el hook de forja corre `engram sync --import` — recibís automáticamente el conocimiento que el equipo commiteó.
- **Al cerrar una unidad de trabajo**: guardá lo aprendido (`mem_save`), corré `engram sync` y commiteá `.engram/` junto con el código. El conocimiento viaja en el mismo PR que lo produjo.
- **Idioma: español.** La búsqueda de engram (FTS5) no cruza idiomas — las memorias de scope `project` se escriben en español, el idioma del equipo, o nadie las encuentra.
- **El sync exporta TODO el proyecto, scope `personal` incluido.** Notas verdaderamente personales van en un proyecto engram separado (p. ej. `<tu-usuario>-notes`), nunca en este. Un secreto dentro de una observación se envuelve en `<private>…</private>` — engram lo redacta a `[REDACTED]` antes de guardar.
- La memoria **complementa** los artefactos versionados (openspec, requerimientos, wiki): registra el porqué y los gotchas; los artefactos siguen siendo la fuente de verdad.
- **engram-cloud (recomendado, no obligatorio).** Replicación de la memoria de equipo vía un server self-hosted, complementaria al git-sync de `.engram/`. Si no está configurada, `/forja:doctor` la marca `WARN` y el hook de sesión te lo recuerda al arrancar — **nunca bloquea**. Para activarla: `engram cloud config --server <url>` + `engram cloud enroll <app>` (el `<app>` es el `project_name` de `.engram/config.json`); verificá con `engram sync --cloud --status --project <app>` (debe dar `enabled: true`).

## Colaboración multi-dev

- **El equipo recibe forja solo.** Al clonar y confiar la carpeta, `.claude/settings.json` registra el marketplace y habilita el plugin — sin setup manual.
- **1 feature = 1 carpeta = 1 agente.** Cada slice es un territorio: un developer (con su agente) por slice, sin pisarse. **El linter de dependencias del proyecto lo impone** — el cruce entre features solo pasa por su API pública, así que dos slices en paralelo no colisionan.
- **Antes de cortar rama, corré `/forja:status`** para ver qué slices están tomados y elegir uno libre.
- **Si al abrir la sesión NO apareció el resumen del proyecto** (o apareció el aviso de contexto DEGRADADO), algo está roto en los hooks o en `.forja.json`: corré `/forja:doctor` antes de trabajar — una sesión sin doctrina ni memoria produce código fuera de norma sin darse cuenta.
- **Cambios al core compartido del proyecto van en PR propio y coordinado**: es territorio común, tocarlo dentro del PR de una feature genera conflictos con todo el equipo.

## Secretos

- **REGLA INVIOLABLE: ningún secreto llega a git/GitHub.** Nunca en código, docs, ejemplos, mensajes de commit ni archivos versionados. Si un secreto entró a git alguna vez: se **rota**, no alcanza con borrarlo.
- **El contrato es nombre del secret = campo del schema de config de la app.** En prod cada campo es un archivo `/run/secrets/<campo>` (Docker secret); la fuente local es `secrets/<env>.env` (gitignored). Para dev local: copiá `.env.example` a `.env` (gitignored) y completá.
- **Pedir keys por chat está OK.** Si una tarea necesita una API key que no tenés, pedísela al usuario directamente — lo que no está OK es persistirla fuera del canal correcto.
- **Token Hetzner Read&Write = break-glass.** No se persiste: se inyecta just-in-time para una operación mutadora aprobada por un humano y se descarta. El loop autónomo opera con el token read.
- **PROHIBIDO anotar secretos en engram.** Un token/clave en una observación se filtra por partida doble: engram sincroniza a un server compartido Y commitea chunks a git. Engram guarda el saber SOBRE el secreto (que existe, dónde va, cómo se rota), nunca su valor. El valor vive solo en el gestor del equipo; el equipo lo materializa con `scripts/materialize-secrets.sh` desde `secrets/secrets-map.json` (onboarding: doctrina ops/13).

## Gates (innegociables)

- **El `check` del contrato (`{{CMD_CHECK}}`) es EL gate, local = CI**: lint + formato + tipos + pureza de dependencias + tests unit + linter de migraciones expand/contract + auditoría de dependencias, según lo defina el stack del proyecto. Lo que corre en tu máquina es exactamente lo que bloquea el merge.
- **El test rojo va primero.** Sin test que falle, no hay código de producción que escribir.
- **Mutation testing corre nightly como MÉTRICA** — no bloquea el merge; subirlo a gate es un punto del dial.
- **Si un gate falla, se arregla el código — JAMÁS el gate.** Debilitar un contrato de dependencias, borrar un test o bajar un umbral para "pasar" es deuda disfrazada de progreso.
