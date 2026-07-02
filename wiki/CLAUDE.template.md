# CLAUDE.md — <NOMBRE_DEL_PROYECTO>

> **Plantilla** (`wiki/CLAUDE.template.md`). Al arrancar un proyecto nuevo: copiala a la raíz
> como `CLAUDE.md` (alias `AGENTS.md`), completá el bloque **Contexto del proyecto** y borrá
> esta nota. No se llama `CLAUDE.md` dentro de la wiki a propósito: Claude Code auto-carga los
> `CLAUDE.md` de subdirectorios, y una plantilla con placeholders no debe inyectarse como
> instrucciones reales.

Doctrina de ingeniería de la agencia: stack, arquitectura, proceso y operaciones para construir software TS/React de calidad. Toda la doctrina vive en `wiki/` y es la **fuente de verdad**: si el código contradice una regla, se corrige el código o se actualiza la regla.

## Contexto del proyecto (completar al instanciar)

| Campo | Valor |
|---|---|
| Aplicación (`APP`) | `<app>` |
| Repositorio | `<org>/<repo>` (privado), cuenta GitHub `<cuenta>` |
| Dominio de producción | `<app>.<dominio>` |
| Dominio de dev/test (Swarm local) | `dev-<app>.<dominio>` |
| Servidor de producción | `<proveedor, nodo y contexto Docker>` |

## Por dónde empezar (lectura obligatoria)

1. **Leé primero `wiki/MANIFIESTO.md`** — el índice máquina-legible: tiers, DAG de lectura, índice tema→doc-dueño y **recetas por tarea**. NO leas la wiki entera; cargá la **receta** de tu tarea (`nueva-feature`, `tocar-auth`, `desplegar`, `operar-servidor`, `rollback`, `arrancar-proyecto`).
2. **Tier 0 (`wiki/fundamentos/`) siempre**; descendé por tiers (proceso → arquitectura → operaciones) bajo demanda.
3. El MANIFIESTO es un artefacto **derivado** del frontmatter de cada doc: no lo edites a mano; lo regenera y valida `node wiki/_meta/validate-graph.mjs`.

## El kit portable del agente (viene dentro de la wiki)

La wiki trae todo lo que el agente necesita para operar; en un proyecto nuevo se instancia así:

- **Reglas** (`wiki/rules/`) → copiá a `.claude/rules/`. El gate `pnpm check:reglas` las mantiene idénticas.
- **Comandos del operador** (`wiki/operaciones/comandos/`) → copiá a `.claude/commands/`, ajustando su bloque "Contexto fijo del proyecto". El gate `pnpm check:comandos` los mantiene idénticos.
- **Skills** (`wiki/skills/`) → enlazá cada uno con `ln -s ../../wiki/skills/<skill> .claude/skills/<skill>` (la forma de symlink por-skill que Claude Code documenta).
- **Esta plantilla** (`wiki/CLAUDE.template.md`) → el `CLAUDE.md` raíz que estás leyendo.

## Flujo de trabajo: de la idea al deploy

| Paso | Qué | Doctrina |
|---|---|---|
| **0. Requerimientos** | Correr la entrevista `spec-doc-interviewer` → genera los documentos de requerimientos | `wiki/proceso/05` |
| **1. SDD** | gentle-ai sobre los requerimientos: propose → spec → design → tasks → apply → verify | `wiki/proceso/03` |
| **2. Código** | Hexagonal + vertical slices + TDD; los 4 caminos del borde; dominio puro | `wiki/arquitectura/` |
| **3. Dev** | Correr y **probar en dev** hasta que la versión esté lista para usar | `wiki/operaciones/02` (dev local) |
| **4. Deploy** | Una vez lista en dev → desplegar | `wiki/operaciones/` |

## Política de ramas (Gitflow) — `main` es PRODUCCIÓN

`main` es la rama de producción: lo que vive en `main` es lo que corre (o va a correr) en el dominio de producción. Está **protegida** y **NUNCA** se commitea ni se pushea directo — todo entra por Pull Request.

El **modelo completo de ramas** (main/develop/feature/release/hotfix, bump en `release/*`, back-merge obligatorio) y las **reglas de commit** (Conventional Commits, un commit = unidad de trabajo) son doctrina portable: viven en `wiki/proceso/01` §Gitflow — leelas antes de tocar ramas o commitear.

Reglas innegociables:

- **Prohibido el push directo a `main`** (y a `develop`): todo cambio entra por PR. Default branch del repo = `develop`.
- Antes de mergear a `main`, el gate `pnpm run check` debe pasar y la versión debe estar probada en dev/test.
- **El deploy a producción se ejecuta con el comando `/deploy`** (Claude Code, `.claude/commands/deploy.md`), NUNCA por CI ni por `deploy.sh` a mano. El tag `vX.Y.Z` es **registro** del release, NO trigger. Rollback en dos planos con `/rollback`: software (barato) y datos (**destructivo y human-confirmed**). GitHub Actions queda SOLO para gates de PR — no despliega. Doctrina: `wiki/operaciones/08`.
- **Enforcement = por convención + preflight.** Si el plan de GitHub no permite branch protection en repos privados, GitHub NO bloquea un push directo: la regla se respeta por disciplina, y el **preflight de `/deploy`** es el control real. Para candado técnico, subir la org a GitHub Team.

## Preferencias de proceso (gentle-ai / SDD)

- **Artifact store: `openspec`.** Los artefactos SDD viven como archivos en `openspec/` (committables, con historial git). NO usar engram como store de artefactos SDD.
- **Engram (memoria persistente): automático y siempre activo.** Guardá decisiones, bugs (con causa raíz), convenciones y descubrimientos **proactivamente**, sin que te lo pidan. Buscá en memoria al arrancar trabajo que pudo hacerse antes.
- **Modo de ejecución en dev: AUTOMÁTICO (auto-chain).** Encadená las fases sin pausar entre ellas; el gatekeeper valida cada fase antes de la siguiente. **NO PARES hasta tener la versión lista para usar y probar en dev** — solo interrumpí ante un bloqueo real o una decisión de negocio que no podés resolver.
- **Despliegue: bajo confirmación.** Cuando la versión esté lista y probada en dev, procedé al despliegue siguiendo `wiki/operaciones/`.

## Manejo de secretos en desarrollo

- **Pedí las keys cuando las necesites.** Si una tarea necesita una API key o secreto que no tenés, **pedísela al usuario directamente en el chat** — no es una preocupación.
- **Administralos como dice la doctrina** (`wiki/operaciones/07`): cada secreto va en `secrets/<env>.env` (gitignored), con el contrato **nombre del secret = nombre del campo** del schema Zod de config. De ahí `deploy.sh` los crea como **Docker secrets** del Swarm → `/run/secrets/` → `config`. Para dev local, `.env` (gitignored).
- **REGLA INVIOLABLE: ningún secreto llega a git/GitHub.** Nunca en código, documentación, ejemplos, mensajes de commit ni ningún archivo versionado. Si alguna vez un secreto entró a git, avisá de inmediato: hay que **rotarlo**, no solo borrarlo.
- **Token de infraestructura read-write = break-glass.** No lo persistas; inyectalo just-in-time solo para una operación mutadora aprobada y descartalo (ver `wiki/operaciones/12`).

## Gates (innegociables — el guardarraíl que importa es ejecutable)

- **`pnpm run check`** bloquea el merge: `tsc --noEmit` (strict) + Biome + dependency-cruiser (contratos de pureza) + Vitest (unit) + linter de migraciones + gates de sync del kit (`check:comandos`, `check:reglas`) + `pnpm audit`. Local = CI.
- **Gate del grafo de la wiki:** `node wiki/_meta/validate-graph.mjs --check` debe pasar tras tocar cualquier doc o su frontmatter.
- **Mutation testing (Stryker):** corre **nightly como métrica**, NO bloquea el merge (subirlo a gate es un punto del dial).
- Cualquier integración de tercero pasa por un **puerto + adaptador** (`<provider>.adapter.ts`) detrás del cliente `core/http`; el contrato `egress-through-httpclient` lo impone.

## Principios que gobiernan todo (de `wiki/fundamentos/01`)

- **Convención sobre configuración**: un default por decisión, impuesto por una herramienta, no por prosa.
- **Robusto no es máximo (el dial)**: la complejidad se agrega solo cuando aparece el dolor que la justifica; las escalaciones diferidas están en el catálogo del dial con su disparador.
- **Una herramienta por área.** **Dominio puro innegociable.** **El test rojo va primero (TDD).**
- **Optimizado para el bucle de la IA**: localidad (una feature = una carpeta) + fronteras (núcleo puro tras puertos) + señales ejecutables (tipos, tests, linters).

## Infra (gestión por agente)

El servidor se gestiona vía API con guardarraíles: el agente usa el wrapper de `wiki/operaciones/` (nunca la CLI cruda del proveedor), opera con token **read** por defecto, y las operaciones destructivas están **prohibidas** (protección a nivel API + human-in-the-loop). Detalle en `wiki/operaciones/12`.
