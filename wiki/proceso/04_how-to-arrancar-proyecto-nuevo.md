---
id: proc.arrancar
titulo: Arrancar un proyecto nuevo
tipo: how-to
tier: 1
audience: both
resumen: Secuencia lineal para inicializar un proyecto desde cero, de instalar el plugin forja hasta publicar en dev y prod.
provides:
  - "Paso 0 - instalar el plugin forja y correr /forja:init (primera acción obligatoria)"
  - "AGENTS.md / CLAUDE.md como ancla de entrada del agente"
  - "plantilla del ancla (CLAUDE.md instanciado por /forja:init desde la plantilla del plugin)"
  - "mapa de lectura mínima (los cuatro docs para una sesión fresca)"
  - "Strict TDD mode (parámetro de configuración de Gentle AI)"
  - "artifact store = openspec (parámetro de configuración)"
  - "modo automático (fases encadenadas sin pausa manual)"
  - "secuencia de arranque de proyecto nuevo (cinco pasos)"
  - "export de claude.ai/design como artefacto (el comando de descarga produce claude_design/; alimenta los tokens --tk-*)"
reads-before: [fund.stack, proc.tdd, proc.sdd]
related: [ops.exponer-tunnel, ops.desplegar-swarm]
---

# Cómo arrancar un proyecto nuevo: de la doctrina a producción

Inicializar un proyecto nuevo de principio a fin: desde instalar el plugin forja —que trae la base de verdad— hasta dejar la app publicada en ambos entornos con su dominio. Flujo lineal —cada paso produce un artefacto que alimenta al siguiente— y ningún eslabón puede omitirse sin afectar lo que viene.

```
plugin forja  →  software_requirements/  →  claude_design/  →  Gentle AI / SDD  →  openspec/  →  src/  →  dev / prod
      0                    1                      2                  3                              3          4
```

Este documento es el orquestador del flujo: da el objetivo de cada paso, qué produce y dónde vive el detalle. No repite lo que ya documentan las piezas enlazadas.

> Este flujo es una **norma del proyecto**, no la bitácora de una ejecución concreta. Si algún paso no se completó aún, se aplica en el orden descrito.

---

## Paso 0 — Instalar el plugin forja y correr `/forja:init`

**Objetivo:** establecer la base de verdad y el andamiaje ejecutable antes de cualquier otra acción.

En un repositorio o carpeta en blanco, el primer movimiento es instalar el plugin **forja** (marketplace `aguerodev/forja`) y correr **`/forja:init`** en la carpeta del proyecto. El comando monta el preflight de herramientas (gentle-ai, engram, gh), el esqueleto ejecutable, Gitflow y el `CLAUDE.md` instanciado. La doctrina **no se copia al proyecto**: viaja dentro del plugin —el stack de desarrollo, los principios de arquitectura, las normas de operación y el marco metodológico que condiciona todo lo que sigue— y se consulta con la skill `forja:doctrina`. Los comandos del operador (`/forja:deploy`, `/forja:rollback`) y las reglas operativas del agente también viven en el plugin: no hay copias por proyecto que mantener sincronizadas.

Los skills del flujo (como `spec-doc-interviewer`, el del paso 1) también viajan dentro del plugin: Claude Code los descubre al instalarlo, sin symlinks ni copias.

El stack de desarrollo está en [Stack de desarrollo](../fundamentos/03_referencia-stack-desarrollo.md).

### El punto de entrada del agente

Un agente de IA arranca cada sesión en frío: no carga el repositorio entero ni recuerda conversaciones previas, y no lee la wiki completa al abrir. Por eso la raíz incluye un `AGENTS.md` (alias `CLAUDE.md`) como **ancla de entrada**: el primer y único archivo que un agente lee sin que se lo indiquen. No duplica la wiki; la indexa. Declara los comandos load-bearing (`pnpm dev`, `pnpm run check`, `pnpm db:generate`/`db:migrate`; el generador de features todavía **no existe** — la receta honesta es copiar un slice existente, ver [Gates y tooling](../arquitectura/07_referencia-gates-tooling.md)), los gates innegociables y el **mapa de lectura mínima** hacia la doctrina:

| Para saber… | Leé |
|---|---|
| Los principios que condicionan todo | [Principios del proyecto](../fundamentos/01_explicacion-principios.md) |
| Dónde vive cada cosa en el árbol | [Estructura del repositorio](../arquitectura/02_referencia-estructura-repo.md) |
| Las convenciones de código (modelado, errores, autorización) | [Convenciones de código](../arquitectura/03_referencia-convenciones-codigo.md) |
| Cómo agregar un contexto de negocio | [Crear una feature](../arquitectura/08_how-to-crear-feature.md) |

Estos cuatro documentos son la lectura mínima para producir código correcto; el resto de la wiki se consulta a demanda desde ellos. El ancla resuelve el hueco entre "la wiki es la base de verdad" y "cómo el agente llega a la wiki".

El ancla no se escribe desde cero: `/forja:init` la instancia en la raíz como `CLAUDE.md` desde la plantilla CLAUDE.md del plugin forja, completando el bloque «Contexto del proyecto» (app, repo, dominios, servidor).

**Produce:** el andamiaje del proyecto (preflight, esqueleto, Gitflow) y el `AGENTS.md`/`CLAUDE.md` raíz que indexa la doctrina del plugin.

---

## Paso 1 — Capturar los requerimientos (`software_requirements/`)

**Objetivo:** fijar qué construir, para quién y bajo qué reglas, antes de diseñar ni implementar nada.

Corre el skill **`spec-doc-interviewer`**: lanza una entrevista estructurada —volcado libre → preguntas de selección → panel de revisión— y genera los seis documentos de requerimientos junto a sus bitácoras de revisión. El procedimiento completo para generarlos —las cuatro fases, los cuatro tipos de pregunta y el panel de revisión— está en [Generar los documentos de requerimientos](./05_how-to-generar-requerimientos.md); la estructura de la carpeta resultante, en [SDD, flujo de especificación y Gentle AI](./03_explicacion-sdd.md).

**Produce:** `software_requirements/` con PRD, glosario, catálogo de requisitos, reglas de negocio y modelo de dominio (más el modelo de datos y `database.dbml`, solo en brownfield u orden explícita).

---

## Paso 2 — Diseñar la interfaz (`claude_design/`)

**Objetivo:** traducir los requerimientos a una propuesta de interfaz y al **sistema de diseño** del proyecto antes de arrancar la implementación.

**`claude.ai/design`** (la web de Claude) es la herramienta oficial de este paso: con `software_requirements/` como insumo se genera ahí la propuesta de UI y el sistema de diseño del proyecto. El resultado **se descarga con el comando de export de la propia herramienta** y se guarda en `claude_design/` — no se copia a mano pantalla por pantalla: el export es el artefacto.

Ese artefacto cumple dos roles aguas abajo:

1. **Insumo de Gentle AI** (junto con `software_requirements/`) para el SDD del paso siguiente.
2. **Base del sistema de diseño**: sus decisiones visuales (colores, radios, tipografía) se traducen a las primitivas `--tk-*` del sistema de tokens en dos capas ([Estilos de frontend](../arquitectura/06_explicacion-estilos-frontend.md)); no se copia CSS suelto del export al árbol de componentes.

**Produce:** `claude_design/` con la propuesta de interfaz y el sistema de diseño exportado.

---

## Paso 3 — Implementar con Gentle AI / SDD (`openspec/`, `src/`)

**Objetivo:** producir el código a partir de los requerimientos y la propuesta de UI, con especificación explícita de cada cambio antes de implementar.

Los insumos de entrada son `software_requirements/` **y** `claude_design/`. Gentle AI arranca con `sdd-init` y luego ejecuta el ciclo SDD completo —proposal → spec → design → tasks → apply → verify → archive— para cada cambio.

El esqueleto del repositorio no se escribe a mano: **Plop** genera el proyecto y cada feature con su forma canónica —el hexágono completo de un slice en una sola carpeta bajo `src/features/`—, así el código nace correcto; `pnpm install` deja el entorno reproducible desde `pnpm-lock.yaml`.

Configuración del flujo en este proyecto:

| Parámetro | Valor |
|---|---|
| TDD | Strict TDD mode activo — los tests se escriben antes que el código |
| Artifact store | `openspec` — los artefactos de cada cambio se guardan como archivos en `openspec/` |
| Modo de ejecución | Automático — las fases corren encadenadas sin pausa manual entre ellas |

El concepto de SDD, la descripción de Gentle AI y la estructura de `openspec/` con la cadena completa de carpetas están en [SDD, flujo de especificación y Gentle AI](./03_explicacion-sdd.md).

El código generado en `src/` sigue la estructura de módulos del proyecto: vertical slices en `src/features/`, core transversal en `src/core/` y bindings mínimos al framework en `src/app/`. La forma completa del árbol está en [Estructura del repositorio](../arquitectura/02_referencia-estructura-repo.md).

El handoff `software_requirements/ → openspec/ → src/` queda trazable: cada cambio de `openspec/` declara qué requisitos de `software_requirements/` (`RF-`/`RNF-`, `RN-`) realiza, y el slice en `src/features/<feature>/` queda ligado a ese cambio —de un archivo de código se sube hasta el requisito que lo motivó, y a la inversa—. Detalle en [SDD, flujo de especificación y Gentle AI](./03_explicacion-sdd.md).

Cada cambio se cierra contra el gate único: `pnpm run check` corre todos los controles que bloquean el merge —tipos con `tsc --noEmit`, lint y formato con Biome, pureza con dependency-cruiser y tests con Vitest— y local equivale a CI. El mutation testing con Stryker no es gate de PR: corre como métrica informativa en un job nightly.

**Produce:** `openspec/` (especificaciones y estado de cada cambio) y `src/` (código).

---

## Paso 4 — Publicar en dev y prod

**Objetivo:** dejar la aplicación accesible en ambos entornos con su dominio.

El cierre del flujo tiene dos sub-pasos, en orden:

1. **Aprovisionar los túneles de Cloudflare.** Un túnel saliente por entorno expone la aplicación sin abrir puertos en el servidor. Procedimiento completo: [Exponer la app por Cloudflare Tunnel](../operaciones/05_how-to-exponer-cloudflare-tunnel.md).

2. **Desplegar el stack en el Swarm.** Despliega la aplicación como stack de Docker Swarm: `prod` en el servidor, `dev` en el Swarm local. Conecta los túneles y deja los dominios sirviendo. Procedimiento completo: [Desplegar el stack en Swarm](../operaciones/06_how-to-desplegar-swarm.md).

La convención de dominios y entornos —qué corre dónde y con qué hostname— está en [Entornos e imagen Docker](../operaciones/02_referencia-entornos-e-imagen.md).

**Produce:** la aplicación publicada en `${APP}.<dominio>` (prod) y accesible localmente en dev.
