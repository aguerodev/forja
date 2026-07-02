---
id: proc.trabajo-ia
titulo: Trabajar con un agente de IA
tipo: explicacion
tier: 1
audience: both
resumen: Cómo cada decisión de arquitectura sirve a las restricciones operativas de un agente de IA con contexto limitado.
provides:
  - sub-agente (unidad que posee una feature de punta a punta)
  - orquestador delgado (nivel director que delega, distinto del nivel de trabajo)
  - gates de fase (revisión en fronteras, no en cada edición)
  - fatiga de aprobación (antipatrón)
  - radio de daño acotado (blast radius)
  - handoff entre fases como artefacto explícito
  - anclas estables (wiki + convenciones + errores explícitos como memoria del agente)
  - "reglas operativas del agente (wiki/rules/ dentro del plugin forja, impuestas por hooks del plugin)"
  - bucle apretado de señales (tipos + tests + linters como canal de control del agente)
  - skills curadas transferibles por convención
  - "Gitflow multi-agente (main producción, develop integración, features cortas; solo main despliega vía /forja:deploy)"
  - "modelo completo de ramas (main/develop/feature/release/hotfix; bump en release/*; back-merge obligatorio main -> develop tras cada release o hotfix)"
  - "reglas de commit (Conventional Commits tipo(scope): imperativo; un commit = unidad de trabajo revisable; sin atribución de IA; commitlint es dial)"
  - "colisiones acotadas por slice (una feature = una carpeta = un agente; Gitflow pone la cadencia encima)"
reads-before: [fund.principios]
related: [arq.hexagonal]
---

# Por qué la arquitectura está pensada para el flujo de un agente

Premisa: buena parte del código lo escribe y modifica un agente de IA que no carga el proyecto entero ni recuerda conversaciones pasadas; trabaja con el contexto que se le pone delante y se autocorrige con las señales que recibe (tipos, tests, linters). La arquitectura del proyecto —monolito modular, vertical slices, núcleo hexagonal, convención sobre configuración— minimiza ese contexto y maximiza esas señales. Concreta el principio [la arquitectura optimiza el bucle de la IA](../fundamentos/01_explicacion-principios.md#la-arquitectura-optimiza-el-bucle-de-la-ia).

## Una feature es una unidad que un sub-agente posee de punta a punta

La [vertical slice](../arquitectura/01_explicacion-arquitectura-hexagonal.md#segunda-decisión-organizar-por-feature-no-por-capa) da límites naturales para repartir trabajo entre fases y sub-agentes sin que se pisen. Una feature es una carpeta autocontenida bajo `src/features/<feature>/`: el sub-agente que la posee carga poco —el hexágono completo en un solo directorio— y el radio de daño de un error queda acotado a ese límite. Organizar por capa esparciría una feature por todo el árbol y obligaría a sostener más contexto del necesario.

## Los contratos son el handoff entre fases

El [puerto](../arquitectura/01_explicacion-arquitectura-hexagonal.md#tercera-decisión-dentro-de-cada-feature-un-núcleo-hexagonal) (la interfaz TypeScript que el dominio define en `ports.ts`) y el esquema OpenAPI permiten que la fase de diseño fije la interfaz y la de implementación la cumpla sin releer todo. El OpenAPI 3.1 que los schemas Zod producen vía `zod-to-openapi` es documentación viva del contrato, para humanos y para la IA: el handoff entre fases es un artefacto explícito, no conocimiento tácito.

## La convención es el sustrato de las skills

Cuanto más uniforme y convencional es el código, más aplica una skill genérica en cualquier feature. [Convención sobre configuración](../fundamentos/01_explicacion-principios.md#convención-sobre-configuración) no es solo menos esfuerzo humano: es lo que hace transferibles las skills, porque una skill que asume un único patrón —el slice canónico que `Plop` genera, con sus `domain.ts`, `ports.ts`, `service.ts`, `schemas.ts` y `repository.ts`— sirve en toda feature que respeta ese patrón.

## El orquestador delgado refleja la capa `app` fina

Mismo principio en dos niveles: arriba, un orquestador delgado conduce y delega; abajo, la lógica vive en el núcleo de dominio y el borde HTTP —los bindings finos de `src/app/` y los handlers de `route.ts`— solo transporta. La conducción se separa del trabajo en ambos planos.

## La memoria persistente necesita anclas estables

La memoria persistente del flujo registra decisiones y bugs entre sesiones; las convenciones del proyecto, la wiki y los errores de dominio explícitos (la jerarquía bajo `DomainError`) son sus puntos de anclaje. Menos decisiones abiertas significan menos deriva que la memoria deba reconciliar: la convención reduce lo que hay que recordar.

## Las reglas operativas del agente derivan de esta wiki

Las reglas que el agente carga en cada sesión viven en `wiki/rules/` **dentro del plugin forja** como imperativos condensados —flujo de git, commits, gates, arquitectura, secretos, deploy y colaboración multi-agente— derivados de esta wiki, que sigue siendo la fuente de verdad: si una regla y su doc dueño divergen, se corrige la regla. Las de mayor riesgo se **imponen con hooks del plugin** —la guardia de Gitflow, la atribución de IA en commits, el choke-point de infra— y el `CLAUDE.md` del proyecto las referencia: no hay copias por proyecto que sincronizar.

## Gates de fase, no aprobación por edición

Se revisa en las fronteras de fase —spec → plan → implementación—, no en cada cambio individual. Revisar cada edición produce fatiga de aprobación y cambio de contexto constante; revisar en las fronteras concentra el juicio humano donde decide. Y la ceremonia se ajusta al riesgo: lo trivial se salta el spec. Conecta con [ceremonia proporcional al riesgo](../fundamentos/01_explicacion-principios.md#ceremonia-proporcional-al-riesgo). El detalle conceptual de este modo de trabajo está en [Qué es Spec-Driven Development](./03_explicacion-sdd.md).

## Gitflow: la cadencia de integración multi-agente

Cuando varias personas —cada una con su agente— tocan el mismo repositorio, el mecanismo que evita las colisiones tiene dos capas, y conviene no confundirlas:

- **La capa estructural son los vertical slices.** Una feature = una carpeta = un agente que la posee de punta a punta. Dos agentes trabajando en features distintas casi no pueden pisarse, porque sus diffs viven en carpetas disjuntas y el cruce entre features pasa solo por `public.ts`. Esta capa la impone dependency-cruiser, no la disciplina.
- **La capa de cadencia es Gitflow.** `main` es producción; `develop` es integración y rama base del trabajo diario; cada cambio nace como `feature/<nombre>` desde `develop` y vuelve por PR con los gates en verde. `release/*` y `hotfix/*` completan el modelo.

El modelo completo de ramas — la doctrina portable que cualquier repo de la agencia hereda:

- **`main`** — producción. Solo recibe merges vía PR desde `release/*` o `hotfix/*`; cada merge a `main` es un release desplegable. Nunca se commitea ni pushea directo.
- **`develop`** — integración y **rama default** del repo (los PR y los clones apuntan acá, no a `main`).
- **`feature/<nombre>`** — un cambio. Sale de `develop`, vuelve a `develop` por PR.
- **`release/<versión>`** — estabilización. Sale de `develop`; **en esta rama se hace el bump de `package.json`**; entra a `main` por PR, y sobre ese merge se corta el tag `vX.Y.Z` (== versión) como registro del release.
- **`hotfix/<nombre>`** — urgencia sobre producción. Sale de `main`, vuelve a `main` **y** a `develop`.
- **Back-merge obligatorio**: tras cada merge a `main` (release o hotfix), `main` vuelve a `develop` por PR. Es el olvido clásico de Gitflow — deja a `develop` con la versión vieja y el próximo release nace mal numerado — y no es opcional.

**Reglas de commit.** El historial es una interfaz operativa —el selector de rollback describe cada versión desplegable por su mensaje de commit—, así que el mensaje no es decorativo:

- **Conventional Commits**: `tipo(scope): resumen imperativo` (`feat`, `fix`, `docs`, `chore`, `refactor`, `test`). El resumen dice **qué**; el cuerpo dice **por qué** cuando no es obvio.
- **Un commit = una unidad de trabajo revisable**: el test y el doc viajan **con** el código que los motiva, nunca en un commit "misc" posterior.
- Sin atribución de herramientas ni co-autorías de IA. Una herramienta de enforcement (commitlint/husky) es entrada del dial; disparador: el primer colaborador que rompa el formato de forma sostenida.

Dos reglas específicas del trabajo con agentes:

1. **Ramas de feature CORTAS.** Un agente genera mucho código rápido: una rama que vive dos semanas acumula un diff gigante contra un `develop` que también se movió rápido, y el merge se vuelve el punto de dolor que el slice había evitado. La feature sale de `develop`, se implementa, pasa los gates y vuelve — días, no semanas.
2. **Solo `main` llega a producción, y el gate es ejecutable.** GitHub (plan free, repo privado) no ofrece branch protection: la regla la impone el **preflight del comando `/forja:deploy`** (rama `main`, tree limpio, al día con `origin/main`, gates verdes, confirmación explícita). El despliegue es reversible en dos planos —software y datos— documentados en [Release por comando](../operaciones/08_how-to-pipeline-cicd.md). Así todos pueden desplegar, y un deploy fallido se revierte en vez de lamentarse.

## El guardarraíl real es ejecutable, no la prosa

Las reglas declaradas en prosa un modelo puede ignorarlas. Lo que de verdad se cumple es lo ejecutable: el scaffolding de `Plop`, `pnpm run check`, los gates de CI que bloquean el merge (`tsc --noEmit`, `biome`, `dependency-cruiser`, `vitest`), el mutation testing con `stryker` como métrica informativa en un job nightly —no gate de PR—, el pipeline de deploy gateado y la suite de dominio en milisegundos. Ese bucle apretado de señales —no el documento— es donde la IA produce código fiable. Es el principio [los guardarraíles que importan son ejecutables](../fundamentos/01_explicacion-principios.md#los-guardarraíles-que-importan-son-ejecutables).
