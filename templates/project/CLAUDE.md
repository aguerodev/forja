# CLAUDE.md — {{PROJECT_NAME}}

Doctrina de ingeniería de la agencia: stack, arquitectura, proceso y operaciones para construir software TS/React de calidad. La fuente de verdad es el **plugin forja** (doctrina + comandos + guardias); este archivo es el ancla del proyecto: contexto propio + las reglas que gobiernan todo. Si el código contradice una regla, se corrige el código o se actualiza la regla — nunca se ignora en silencio.

## Contexto del proyecto

| Campo | Valor |
| --- | --- |
| Aplicación (`APP`) | `{{APP}}` |
| Repositorio | `{{GH_ORG}}/{{GH_REPO}}` |
| Dominio de producción | `{{PUBLIC_NAME}}.{{DOMAIN}}` |
| Dominio de dev/test (Swarm local) | `dev-{{PUBLIC_NAME}}.{{DOMAIN}}` |
| Contexto Docker de prod | `{{APP}}-prod` |
| Node | `{{NODE_VERSION}}` |
| PostgreSQL | `{{PG_MAJOR}}` |

> La copia machine-readable de este contexto vive en `.forja.json` (la leen los comandos del plugin y los hooks). Si cambiás un valor acá, actualizá `.forja.json` en el mismo commit — mantenelas en sincronía.

## El plugin forja

- **La doctrina se carga por el skill `forja:doctrina`**, que trae el MANIFIESTO con el índice por tiers y **recetas por tarea** (`nueva-feature`, `tocar-auth`, `desplegar`, `rollback`, `operar-servidor`, `arrancar-proyecto`). Cargá la receta de tu tarea; **NO leas la wiki entera**.
- **Comandos del operador**: `/forja:deploy` (release a prod), `/forja:rollback` (dos planos: software barato, datos destructivo y human-confirmed), `/forja:status` (estado del stack y del trabajo), `/forja:doctor` (diagnóstico del entorno).
- **Guardias activas** (hooks del plugin, no opcionales):
  - Push/commit directo a `main` o `develop` **bloqueado** — todo entra por PR.
  - Atribución de IA en commits **bloqueada** (sin `Co-Authored-By`, sin "Generated with").
  - `hcloud` crudo **bloqueado** — la infraestructura se gestiona vía `hcloud-agent.sh` (en el PATH), con token read por defecto y break-glass humano para mutaciones.

## Flujo: de la idea al deploy

| Paso | Qué |
| --- | --- |
| **0. Requerimientos** | Correr la entrevista `spec-doc-interviewer` → genera los documentos en `software_requirements/` |
| **1. SDD** | gentle-ai sobre los requerimientos: propose → spec → design → tasks → apply → verify (artifact store `openspec`) |
| **2. Código** | Hexagonal + vertical slices + **TDD estricto** (el test rojo va primero); los 4 caminos del borde; dominio puro |
| **3. Dev** | Correr y **probar en dev** hasta que la versión esté lista para usar |
| **4. Deploy** | Una vez probada en dev → `/forja:deploy` |

## Política de ramas (Gitflow) — `main` es PRODUCCIÓN

- **`main` = producción, protegida.** Lo que vive en `main` es lo que corre (o va a correr) en `{{PUBLIC_NAME}}.{{DOMAIN}}`. **NUNCA** se commitea ni se pushea directo.
- **`develop` = rama default.** Integración continua del equipo; tampoco recibe push directo.
- **`feature/*`** nace de `develop` y vuelve por PR. **`release/*`** prepara el corte: el **bump de versión se hace SOLO en `release/*`**. **`hotfix/*`** nace de `main` para el incendio.
- **Back-merge obligatorio**: todo lo que entra a `main` (release u hotfix) vuelve a `develop`.
- Ningún PR se mergea sin `pnpm run check` **verde**.
- **Enforcement en tres capas**: la convención del equipo + la guardia del plugin (bloquea push/commit directo a `main`/`develop` en local) + el **preflight de `/forja:deploy`** (nada llega a prod si no es `main`, limpio, al día y con gates verdes). Si el plan de GitHub no ofrece branch protection, el candado real es ese preflight.

## Preferencias de proceso (gentle-ai / SDD)

- **Artifact store: `openspec`.** Los artefactos SDD (proposal, spec, design, tasks) viven como archivos en `openspec/` — committeables, con historial git, compartibles con el equipo. **NO usar engram como store de artefactos SDD.**
- **Engram = memoria personal del developer, SIEMPRE activa.** Guardá decisiones, bugs con causa raíz, convenciones y descubrimientos proactivamente. Pero lo que el EQUIPO necesita compartir va en artefactos versionados (openspec, wiki del repo, PRs), no en la memoria de una sola persona.
- **Modo de ejecución: AUTOMÁTICO (`auto-chain`).** Encadená las fases SDD sin pausar; el gatekeeper valida cada fase antes de la siguiente. No pares hasta tener la versión lista para probar en dev — interrumpí solo ante un bloqueo real o una decisión de negocio que no podés resolver.
- **TDD estricto.** El test rojo va primero; el runner es `pnpm test:unit` (proyecto `unit` de Vitest, sin I/O).

## Colaboración multi-dev

- **El equipo recibe forja solo.** Al clonar y confiar la carpeta, `.claude/settings.json` registra el marketplace y habilita el plugin — sin setup manual.
- **1 feature = 1 carpeta = 1 agente.** Cada slice de `src/features/<feature>/` es un territorio: un developer (con su agente) por slice, sin pisarse. **dependency-cruiser lo impone** — el cruce entre features solo pasa por `public.ts`, así que dos slices en paralelo no colisionan.
- **Antes de cortar rama, corré `/forja:status`** para ver qué slices están tomados y elegir uno libre.
- **Cambios a `src/core/` o `src/shared/` van en PR propio y coordinado**: son territorio común, tocarlos dentro del PR de una feature genera conflictos con todo el equipo.

## Secretos

- **REGLA INVIOLABLE: ningún secreto llega a git/GitHub.** Nunca en código, docs, ejemplos, mensajes de commit ni archivos versionados. Si un secreto entró a git alguna vez: se **rota**, no alcanza con borrarlo.
- **El contrato es nombre del secret = campo del schema Zod de `src/core/config.ts`.** En prod cada campo es un archivo `/run/secrets/<campo>` (Docker secret); la fuente local es `secrets/<env>.env` (gitignored). Para dev local: copiá `.env.example` a `.env` (gitignored) y completá.
- **Pedir keys por chat está OK.** Si una tarea necesita una API key que no tenés, pedísela al usuario directamente — lo que no está OK es persistirla fuera del canal correcto.
- **Token Hetzner Read&Write = break-glass.** No se persiste: se inyecta just-in-time para una operación mutadora aprobada por un humano y se descarta. El loop autónomo opera con el token read.

## Gates (innegociables)

- **`pnpm run check` es EL gate, local = CI**: biome + prettier (orden de clases Tailwind) + `tsc --noEmit` (strict) + dependency-cruiser (los seis contratos de pureza) + Vitest `unit` + linter de migraciones expand/contract + `pnpm audit`. Lo que corre en tu máquina es exactamente lo que bloquea el merge.
- **El test rojo va primero.** Sin test que falle, no hay código de producción que escribir.
- **Mutation testing (Stryker) corre nightly como MÉTRICA** — no bloquea el merge; subirlo a gate es un punto del dial.
- **Si un gate falla, se arregla el código — JAMÁS el gate.** Debilitar un contrato de dependency-cruiser, borrar un test o bajar un umbral para "pasar" es deuda disfrazada de progreso.
