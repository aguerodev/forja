---
id: proc.sdd
titulo: SDD, flujo de especificación y Gentle AI
tipo: explicacion
tier: 1
audience: both
resumen: Spec-Driven Development como método, la cadena de artefactos que lo soporta y Gentle AI como configurador que lo ejecuta.
provides:
  - "Spec-Driven Development (SDD)"
  - "roadmap derivado (requisitos de software_requirements sin realizar + changes activos de openspec; nunca una lista aparte; el tablero de intake es dial)"
  - "fases sucesivas (especificación -> plan -> implementación)"
  - "artefacto explícito por fase"
  - "fronteras de fase"
  - "deriva del agente"
  - "Gentle AI"
  - "Engram"
  - "memoria de equipo (engram git sync: chunks versionados en .engram/, import al abrir sesión, sync + commit al cerrar la unidad de trabajo)"
  - "modelo distinto por fase"
  - "sdd-init"
  - "cadena de artefactos software_requirements/ -> claude_design/ -> openspec/"
  - "software_requirements/"
  - "claude_design/"
  - "openspec/"
  - "identificadores de trazabilidad RF-/RNF-/RN-/INC-"
  - "delta specs / specs vigentes / capability"
  - "spec-doc-interviewer"
  - "lenguaje ubicuo"
  - "artifact-store"
  - "formatos de artefactos (catálogo de requisitos SRS ligero, dbdocs, Mermaid classDiagram)"
reads-before: [fund.principios, proc.trabajo-ia]
related: [arq.crear-feature]
---

# SDD, flujo de especificación y Gentle AI

Spec-Driven Development (SDD, desarrollo guiado por especificación): se especifica y planifica antes de implementar, y el trabajo avanza por fases con revisión en sus fronteras. Tres cosas encadenadas: el **método** (qué es SDD y por qué encaja con desarrollo asistido por IA), la **cadena de artefactos** que lo soporta de los requerimientos al código, y **Gentle AI**, el configurador que ejecuta el flujo sobre el agente.

## Qué es Spec-Driven Development

El flujo separa el desarrollo en fases sucesivas —especificación, plan, implementación—, cada una con un **artefacto explícito** que la siguiente consume. La intención se fija en la spec antes de escribir código; el plan deriva de la spec; la implementación cumple el plan. La revisión humana ocurre en las **fronteras de fase**, no en cada edición de código: se aprueba la spec, se aprueba el plan, se revisa la implementación.

### Por qué encaja con el desarrollo asistido por IA

Revisar cada cambio individual produce fatiga de aprobación y cambio de contexto constante, y deja que la intención del agente derive sin punto de control. Concentrar la revisión en las fronteras de fase ataca ambas: reduce la fatiga —el humano juzga donde su decisión importa— y acota la **deriva del agente**, porque cada fase parte de un artefacto aprobado en lugar de improvisar sobre el código en curso. La ceremonia se ajusta al riesgo: un cambio trivial se salta la spec; una feature de producción la atraviesa entera. Ver [ceremonia proporcional al riesgo](../fundamentos/01_explicacion-principios.md#ceremonia-proporcional-al-riesgo).

Cómo la arquitectura del código materializa el flujo —orquestador delgado, sub-agentes por fase, los contratos como handoff— está en [Trabajar con un agente de IA](./01_explicacion-trabajo-con-ia.md).

## El flujo de especificación: de los requerimientos al código

Antes de escribir código, el proyecto produce tres capas de artefactos en carpetas dedicadas, cada una alimentando a la siguiente: los **requerimientos** (qué construir y para quién), la **propuesta de interfaz** (cómo se ve) y las **especificaciones de cambio** (cómo se implementa cada cambio concreto).

```
spec-doc-interviewer (skill)  ->  software_requirements/
       requerimientos               │
                                    ├──>  claude.ai/design  ->  claude_design/
                                    │                            propuesta UI
                                    │                                 │
                                    └─────────────────────────────────┤
                                                                       ▼
                                                         Gentle AI / SDD  ->  openspec/  ->  src/
                                                             proceso         specs/cambio    codigo
```

### `software_requirements/` — los requerimientos

La crea el skill **`spec-doc-interviewer`** mediante entrevista (volcado libre + preguntas de selección + panel de revisión). Es la base de verdad de requerimientos y el insumo que Gentle AI consume para arrancar su SDD. Nombre de carpeta fijo, estructura predecible:

```
software_requirements/
├── README.md                 indice: estado por documento, INC resueltas, rondas de revision
├── 00-handoff.md             contrato de handoff dirigido al agente (mapea cada doc a la fase SDD que alimenta e incluye el backlog de cambios candidatos)
├── 01-prd.md                 PRD — el porque y para quien
├── 02-glosario.md            lenguaje ubicuo: un termino por concepto
├── 03-requisitos.md          catalogo de requisitos a nivel capacidad (SRS ligero) — que debe hacer el sistema (RF/RNF)
├── 04-reglas-de-negocio.md   catalogo de politicas e invariantes (RN)
├── 05-modelo-de-dominio.md   entidades y relaciones (Mermaid classDiagram)
├── 06-modelo-de-datos.md     (solo brownfield u orden explicita) base existente como restriccion (prosa + flujo dbdocs)
├── database.dbml             (solo brownfield) esquema existente en DBML, se publica con dbdocs
├── schema.sql                (solo brownfield, opcional) DDL generado desde el DBML
└── review/                   bitacoras del panel de revision, una por documento
    └── 01-prd.review.md … 05-modelo-de-dominio.review.md (y 06 si se creo)
```

Los documentos forman una cadena: el catálogo de requisitos, las reglas, el dominio y el modelo de datos usan los términos del **glosario** (el **lenguaje ubicuo**: un término por concepto); el modelo de dominio se construye sobre las entidades del catálogo y las reglas; el modelo de datos realiza el dominio en persistencia. Los identificadores son trazables: `RF-`/`RNF-` (requisitos), `RN-` (reglas), `INC-` (inconsistencias detectadas y resueltas).

### `claude_design/` — la propuesta de interfaz

La genera **`claude.ai/design`** a partir de los documentos de `software_requirements/`. Junto con `software_requirements/`, es uno de los dos insumos que Gentle AI recibe al arrancar el SDD. Su estructura interna y proceso de generación quedan fuera de alcance; lo relevante es que `claude_design/` es el eslabón entre los requerimientos y la implementación.

### `openspec/` — las especificaciones de cambio

La crea **Gentle AI** cuando el artifact-store del SDD es `openspec` (o `hybrid`). Con el store `engram`, los mismos artefactos viven en memoria persistente y esta carpeta no aparece. Esta doctrina fija **`openspec` como default del equipo**: los artefactos de cambio son archivos versionados que cualquiera puede revisar en el PR. Cada cambio es una carpeta bajo `changes/`, con los artefactos que el flujo SDD produce por fase (proposal → spec → design → tasks → apply → verify → archive):

```
openspec/
├── specs/                    specs vigentes por capability (tras archivar los cambios)
│   └── <capability>/spec.md
└── changes/
    ├── <nombre-del-cambio>/
    │   ├── proposal.md        intencion, alcance y enfoque del cambio
    │   ├── specs/             delta specs: los requisitos que el cambio agrega o altera
    │   │   └── <capability>/spec.md
    │   ├── design.md          decisiones tecnicas y arquitectura del cambio
    │   ├── tasks.md           checklist de implementacion, ordenado por dependencias
    │   └── state.yaml         estado y grafo de fases del cambio (lo lee el dispatcher)
    └── archive/
        └── <nombre-del-cambio>/   cambios completados, ya verificados y archivados
```

Al archivar un cambio, sus **delta specs** se integran en las **specs vigentes** de `specs/` y la carpeta del cambio pasa a `changes/archive/`. La estructura exacta la gestionan Gentle AI y OpenSpec; aquí se documenta la forma esperada.

### La cadena, de punta a punta

1. `software_requirements/` fija los requerimientos del proyecto (estables, evolucionan poco).
2. `claude_design/` traduce esos requerimientos a una propuesta de interfaz; junto con `software_requirements/`, es el insumo de entrada de Gentle AI.
3. Cada cambio concreto nace como `openspec/changes/<cambio>/` y atraviesa las fases del SDD.
4. La implementación cae en `src/features/<feature>/` —el hexágono completo de cada vertical slice, los archivos canónicos— siguiendo la [receta para crear una feature](../arquitectura/08_how-to-crear-feature.md), que fija la lista única de archivos del slice. El enrutado (Route Handlers y páginas) vive en `src/app/` como binding fino; la lógica de dominio, el servicio, los schemas Zod y el adaptador de repositorio pertenecen al slice bajo `src/features/`. El `route.ts` de cada slice registra además sus operaciones en el `OpenAPIRegistry` central: el **contrato OpenAPI se ensambla desde los slices**, no se redacta aparte (detalle en [Ensamblado del contrato OpenAPI](../arquitectura/07_referencia-gates-tooling.md#ensamblado-del-contrato-openapi)).
5. Al archivar, las specs del cambio se consolidan en `openspec/specs/`, que refleja el estado vigente del sistema.

**Trazabilidad del handoff.** La cadena `software_requirements/ → openspec/ → src/` es rastreable de punta a punta por los identificadores que `software_requirements/` fija (`RF-`/`RNF-`, `RN-`): cada `proposal.md` y cada delta spec bajo `openspec/changes/<cambio>/` declara qué requisitos realiza, y el slice resultante bajo `src/features/<feature>/` queda ligado a ese cambio. De un archivo de `src/` se sube al cambio de `openspec/` que lo originó, y de ahí al requisito de `software_requirements/` que lo motivó —y a la inversa, de un requisito se baja al código que lo cumple—. Ningún eslabón inventa alcance: cada capa solo concreta lo que la anterior fijó.

**El roadmap es derivado, no mantenido.** La misma cadena responde "¿qué viene / qué falta?" sin ningún artefacto nuevo: el roadmap ES los requisitos de `software_requirements/` (incluidas las marcas `[PENDIENTE]`) que ningún cambio archivado realizó todavía, más los `openspec/changes/` activos (lo que está en vuelo). Una idea nueva entra como requisito o `[PENDIENTE]` en `software_requirements/` **antes** de volverse un change — así el roadmap nunca se desactualiza porque no existe como lista aparte. Un tablero de intake (Issues/Projects) es entrada del dial; disparador: un stakeholder externo que necesite ver o priorizar el backlog sin leer el repo.

## Qué es Gentle AI

Gentle AI es un **configurador de ecosistema** sobre el agente de IA (por ejemplo Claude Code u OpenCode): no reemplaza al agente, lo equipa para ejecutar el flujo SDD descrito arriba.

### Qué añade sobre el agente

- **Memoria persistente (Engram).** Registra decisiones y bugs entre sesiones, de modo que el conocimiento no se pierde al cerrar una conversación. Y es memoria **del proyecto, compartida por git**: `engram sync` exporta las memorias nuevas como chunks versionados en `.engram/` (content-hashed e inmutables: dos devs exportan en paralelo sin pisarse; si `manifest.json` conflictúa en un merge se resuelve uniendo ambas listas de chunks — nunca descartando entradas, porque el import se guía solo por el manifest) y cada sesión arranca importando los del resto del equipo (`engram sync --import`; el hook de forja lo corre solo). El ciclo operativo —sync + commit de `.engram/` al cerrar cada unidad de trabajo, idioma español para las memorias de proyecto, qué NO va ahí— vive en el `CLAUDE.md` del proyecto («Memoria de equipo (engram)»). La memoria no reemplaza a los artefactos: los requisitos y specs siguen en `software_requirements/` y `openspec/`; los chunks aportan el porqué, los gotchas y las decisiones que los artefactos no capturan.
- **Un flujo de Spec-Driven Development** con un **orquestador delgado** y **sub-agentes especializados por fase**: la conducción queda arriba y el trabajo de cada fase en su sub-agente.
- **Skills curadas.** Capacidades reutilizables que el agente aplica de forma uniforme entre features.
- **Modelo distinto por fase.** Permite asignar un modelo potente para diseñar, uno rápido para implementar y uno barato para explorar, según lo que cada fase exige.

El ciclo arranca con **`sdd-init`**, el comando que detecta el stack del proyecto, bootstrapea el backend de persistencia (el artifact-store: `openspec` —el default del equipo que esta doctrina fija—, `engram` o `hybrid`) y deja el contexto listo para las fases siguientes.

### Por qué la arquitectura del proyecto lo hace rendir

La forma del código está pensada para que el flujo rinda; cada decisión de [Trabajar con un agente de IA](./01_explicacion-trabajo-con-ia.md) tiene su contraparte aquí:

- **Vertical slices** dan a cada sub-agente una unidad que posee de punta a punta, con radio de daño acotado a su carpeta.
- **Los contratos** (puerto, OpenAPI) son el handoff entre fases: la fase de diseño fija la interfaz y la de implementación la cumple sin releer todo.
- **La convención** es el sustrato que vuelve transferibles las skills: cuanto más uniforme el código, más aplica una skill genérica en cualquier feature.
- **Las anclas estables** —wiki, convenciones, errores de dominio explícitos— dan a la memoria persistente puntos de anclaje y reducen la deriva que debe reconciliar.

La descripción se ciñe a lo que el proyecto declara de Gentle AI; el detalle operativo de comandos y fases no es alcance de la wiki. El procedimiento completo para arrancar un proyecto nuevo —de la doctrina a producción— está en [Arrancar un proyecto nuevo](./04_how-to-arrancar-proyecto-nuevo.md).
