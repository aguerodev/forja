---
name: spec-doc-interviewer
description: 'Entrevistador interactivo que construye la documentación base de un proyecto de software (PRD, Glosario, catálogo de requisitos —SRS ligero, nivel capacidad—, catálogo de reglas de negocio, modelo de dominio conceptual y, solo brownfield u orden explícita, el modelo de datos existente) mediante entrevistas. Principio rector: captura solo las decisiones que únicamente el humano puede tomar (negocio, dominio, reglas, límites); lo derivable —Gherkin por cambio, diseño técnico, esquema, tareas— es trabajo aguas abajo de gentle-ai. Para cada documento hace un volcado libre y luego 30+ preguntas de selección única o múltiple de cuatro tipos: exploratorias, aclaratorias, de calidad (sugieren la mejor práctica o decisión de calidad en el ámbito del documento) y de contradicción (detectan y evidencian inconsistencias), alimentándose de los documentos previos, y redacta el resultado en la carpeta software_requirements/, incluyendo software_requirements/00-handoff.md: el mapa de handoff a gentle-ai que indica a cada fase SDD (proposal, spec, design, tasks) qué documentos leer y el backlog de cambios candidatos, más el skill compañero skills/software-requirements-context/SKILL.md en la raíz del proyecto, que el registro de skills de gentle-ai auto-inyecta en sus fases SDD. Antes de liberar cada documento, un panel de 3 rondas × 5 agentes Opus en paralelo caza inconsistencias y ambigüedades. Úsalo siempre que el usuario quiera arrancar la documentación de un proyecto, crear un PRD o SRS, definir reglas de negocio, un modelo de dominio o de datos, preparar documentos para desarrollo guiado por especificación (SDD/spec-driven) con IA o el handoff a gentle-ai, o diga cosas como "entrevístame" o "documentemos el proyecto", aunque no diga la palabra "skill".'
---

# Spec Doc Interviewer

Construye, mediante entrevista, la documentación fundacional de un proyecto de software. El resultado es una carpeta `software_requirements/` que sirve como base de verdad para que una IA (o un equipo) programe con calidad usando desarrollo guiado por especificación (SDD) y TDD. La carpeta `software_requirements/` es precisamente el insumo de entrada que después consume **gentle-ai** para iniciar su proceso de SDD; por eso el nombre es fijo y la estructura, predecible.

## Qué construye (en este orden)

Cada documento tiene su **agente especializado** en `references/`:

1. **PRD** → `references/01-prd.md` — el porqué y para quién.
2. **Glosario (lenguaje ubicuo)** → `references/02-glosario.md` — vocabulario único.
3. **Catálogo de requisitos (nivel capacidad)** → `references/03-requisitos.md` — qué necesita el negocio y por qué (SRS ligero).
4. **Catálogo de reglas de negocio** → `references/04-reglas-de-negocio.md` — políticas e invariantes.
5. **Modelo de dominio (conceptual)** → `references/05-modelo-de-dominio.md` — entidades y relaciones.
6. **Modelo de datos** → `references/06-modelo-de-datos.md` — **SOLO brownfield u orden explícita**: documenta la base existente como restricción de hecho, **en DBML** publicado con **dbdocs**.

**No cargues todos a la vez**: lee solo el archivo del documento en el que trabajas. Además, el **panel de revisión** (Fase 4) que se aplica a todos los documentos está en `references/panel-revision.md`.

## Principio rector: cadena de dependencias

Los documentos forman una cadena. Antes de empezar cualquier documento que no sea el primero, **lee de `software_requirements/` los documentos ya redactados** y úsalos para dos cosas: (a) heredar el contexto y el vocabulario, y (b) **generar preguntas nuevas** —aclaratorias, de calidad y de contradicción— específicas para lo que esos documentos dicen, además del banco del agente. Esto es la retroalimentación que hace que cada etapa pregunte mejor que la anterior.

Reglas de herencia: el catálogo de requisitos, las reglas, el dominio y el modelo de datos usan **exactamente los términos del Glosario** (si necesitas uno nuevo, agrégalo allí). El modelo de dominio se construye sobre las capacidades del catálogo de requisitos y las reglas. El modelo de datos, cuando existe (solo brownfield), documenta la base actual como restricción de hecho frente al dominio y las reglas.

## Principio de alcance: solo decisiones humanas

Este entrevistador captura **solo las decisiones que únicamente el humano puede tomar**: negocio, dominio, reglas y límites. Todo lo derivable es trabajo aguas abajo de gentle-ai: el Gherkin por cambio (`sdd-spec`), el diseño técnico y de agregados (`sdd-design`), el esquema nuevo (`sdd-design`/`sdd-apply`) y las tareas (`sdd-tasks`). Los documentos alimentan a gentle-ai; nunca pre-hacen sus fases.

## Tipos de pregunta y formato (clave de este skill)

**Todas las preguntas de la entrevista son de selección**, para que el usuario responda tocando opciones en vez de escribir ensayos:

- **Modo**: `U` = selección única · `M` = selección múltiple.
- **Opción de escape**: la última opción SIEMPRE permite salir — "Otro (lo escribo)" o "No lo sé aún → [PENDIENTE]". Así nada se pierde y nadie queda forzado. Cuando el usuario la elija, captura el texto libre o marca el hueco.

Cada pregunta además tiene un **tipo**:

- **E — Exploratoria**: descubre qué existe, abre el territorio.
- **A — Aclaratoria**: precisa o desambigua algo ya dicho (o algo vago en un documento previo).
- **Q — De calidad**: propone la mejor práctica o decisión de calidad en el ámbito del documento (negocio, dominio, lenguaje) con una opción **recomendada (★)** y un porqué de una línea. No solo recoge información: sugiere la mejor práctica.
- **X — De contradicción / consistencia**: confronta respuestas entre sí o contra los documentos previos para detectar conflictos. Cada conflicto se registra y se **evidencia** en el documento.

Notación en los archivos-agente: `[E·M]`, `[A·U]`, `[Q·U]`, `[X·U]`. El `★` marca la opción recomendada en preguntas de calidad. Las opciones de los bancos son **plantillas**: adáptalas y añade las propias del dominio del usuario.

## Protocolo universal de 3 fases

### Fase 0 — Arranque
- Si `software_requirements/` no existe, créala junto con `software_requirements/README.md` (índice de estado); si falta `software_requirements/00-handoff.md`, créalo a partir de la plantilla fija de la sección «Handoff a gentle-ai» (más abajo en este archivo).
- Si falta `skills/software-requirements-context/SKILL.md` en la raíz del proyecto, créalo según la sección «Skill compañero para gentle-ai». La instalación estándar de gentle-ai refresca el registro de skills automáticamente en cada prompt (hook `UserPromptSubmit`); si ese hook no está activo, recuérdale al usuario ejecutar `gentle-ai skill-registry refresh` (o `/sdd-init` si nunca se corrió).
- Confirma el documento. Si arrancan de cero, recomienda el orden 1 → 5; el 6 SOLO si hay base de datos existente (brownfield) o pedido explícito.
- Para los documentos 2–5 (y el 6 si se crea), **lee primero** los documentos previos (los que indique el agente en "Entradas") y, a partir de ellos, **prepara preguntas A, Q y X específicas** además del banco del agente.
- Carga el archivo-agente correspondiente.

### Fase 1 — Volcado libre
- Presenta el prompt de volcado libre del agente.
- Pide al usuario que escriba con sus palabras **todo lo que sepa**, sin orden ni filtro. **No interrumpas con preguntas todavía.** Si escribe poco, anímalo con una o dos preguntas abiertas.

### Fase 2 — Entrevista (30+ preguntas de selección, según documento)
- Usa el banco del agente; **todas las preguntas son U o M**. Hazlas por bloques temáticos de 5–8; no las dispares todas de golpe.
- **Adapta las opciones** al proyecto: rellena las que dicen "(el agente lista…)" con lo que salió del volcado y de los documentos previos.
- **Preguntas Q**: di la recomendación (★) y una frase de porqué al ofrecerla.
- **Preguntas X**: ejecuta los chequeos del agente de forma continua y **contra los documentos previos**. Cuando detectes un conflicto, formula una pregunta de selección única que presente las opciones en conflicto para que el usuario decida, y registra la resolución como `INC-xx`.
- **Adapta**: si el volcado ya respondió algo, no lo repitas; confirma o pide precisión (aclaratoria). Salta lo que no aplique.
- Lleva la cuenta de los temas cubiertos al cerrar cada bloque.

### Fase 3 — Redacción
- Redacta el documento con la plantilla del agente, usando el vocabulario del glosario.
- Marca lo no resuelto: `[SUPUESTO: ...]`, `[PENDIENTE: ...]`, `[DECISIÓN ABIERTA: A / B]`.
- **Evidencia las contradicciones**: incluye SIEMPRE la sección `## Inconsistencias detectadas y su resolución`, con entradas `INC-01`, `INC-02`… (descripción del conflicto, fuentes en conflicto, decisión tomada). Donde una decisión resolvió un conflicto, deja una marca inline `[INC-xx]`.
- Asigna **identificadores trazables**: RF-/RNF- (requisitos), RN- (reglas), INC- (inconsistencias).
- Guarda en `software_requirements/` con el nombre que indica el agente. Actualiza `software_requirements/README.md`. Tras la liberación del catálogo de requisitos (doc 03), actualiza el «Backlog de cambios candidatos» de `software_requirements/00-handoff.md` al redactar cada documento posterior (04–05, y 06 si se creó), usando solo IDs RF-/RNF-/RN- ya liberados —nunca los del borrador en revisión— (ver «Handoff a gentle-ai»).

### Fase 4 — Panel de revisión (3 rondas × 5 agentes Opus)
Ningún documento se libera sin pasar este gate. Detalle completo en `references/panel-revision.md`.

- Tras la Fase 3, somete el borrador a **5 agentes revisores** que, **de forma independiente y en paralelo**, buscan inconsistencias, ambigüedades, omisiones y riesgos, cada uno con una lente distinta (consistencia/trazabilidad · ambigüedad/testabilidad · completitud/casos borde · factibilidad técnica · negocio/alcance).
  - En **Claude Code / Cowork**: lánzalos como **5 subagentes en paralelo usando el modelo Opus**.
  - En **claude.ai** (sin subagentes): adopta las 5 lentes una por una sobre el mismo borrador y luego consolida.
- **Tras cada ronda de crítica viene un ciclo de repregunta**: consolida los 5 informes y convierte los hallazgos en repreguntas de selección (U/M) para que el usuario decida; aplica los ajustes al borrador. Las inconsistencias resueltas se registran como `INC-xx`.
- Repite el ciclo **3 rondas**. **Libera** el documento solo cuando se completaron las 3 rondas y no quedan hallazgos de severidad Alta sin resolver. Guarda la bitácora en `software_requirements/review/<NN-doc>.review.md`.
- Complementa (no reemplaza) las preguntas X de la Fase 2: aquéllas cazan conflictos mientras se recoge la información; el panel revisa el documento terminado de forma independiente.

### Cierre de cada documento
- El documento se considera **liberado** solo tras pasar la Fase 4. Al liberarlo: resume lo capturado, lista los `[PENDIENTE]` y las inconsistencias detectadas y cómo se resolvieron, y marca ✅ en `software_requirements/README.md` (con las 3 rondas registradas).
- Tras liberar el catálogo de requisitos (doc 03) —momento en el que ya existen IDs RF-/RNF-— llena el «Backlog de cambios candidatos» de `software_requirements/00-handoff.md`, y vuelve a actualizarlo tras liberar cada documento posterior (nuevas RN, entidades o restricciones pueden cambiar riesgos y dependencias).
- Propón el siguiente documento de la cadena.

## Reglas de calidad (transversales)

- **No inventes.** Si no se sabe, marca `[PENDIENTE]` o `[SUPUESTO]`.
- **Atómico y verificable.** Una afirmación comprobable por requisito/regla; si mezcla varias cosas, sepárala.
- **Trazabilidad.** Usa IDs y cita derivaciones (p. ej. RN-014 responde a RF-007).
- **Detecta y evidencia contradicciones.** Nunca "arregles" un conflicto en silencio: regístralo en la sección de inconsistencias con su resolución y su origen.
- **Sugiere calidad.** Cuando una pregunta Q llevó a elegir una mejor práctica, refléjalo; si el usuario eligió algo subóptimo, déjalo anotado como riesgo o `[DECISIÓN ABIERTA]`.
- **Coherencia de lenguaje.** Mismo término para la misma cosa, alineado al glosario.
- **Idioma y formato.** Español (o el que pida el usuario), Markdown limpio, tablas para catálogos, Mermaid: `classDiagram` para el dominio; el ER de datos se genera desde `database.dbml`.
- **El usuario manda el ritmo.** Si quiere ir rápido, agrupa preguntas; si quiere pausar, guarda el avance parcial en `software_requirements/`.

## Convenciones de salida

```
software_requirements/
  README.md                  índice, estado, INC y rondas de revisión por documento
  00-handoff.md              contrato para agentes SDD: mapea cada documento a las fases de gentle-ai que alimenta + backlog de cambios candidatos
  01-prd.md
  02-glosario.md
  03-requisitos.md
  04-reglas-de-negocio.md
  05-modelo-de-dominio.md
  06-modelo-de-datos.md          (solo brownfield/opcional) documento de la base existente (prosa + flujo dbdocs)
  database.dbml                  (solo brownfield/opcional) esquema existente en DBML, se publica con dbdocs
  schema.sql                     (solo brownfield/opcional) DDL de referencia generado desde el DBML con dbml2sql
  review/                        bitácoras del panel de revisión (Fase 4), una por documento
    01-prd.review.md … 05-modelo-de-dominio.review.md (y 06-modelo-de-datos.review.md si el doc 06 se creó)
```

Además, **fuera de `software_requirements/`**: `skills/software-requirements-context/SKILL.md` (raíz del proyecto) — skill compañero que el registro de skills de gentle-ai indexa para auto-inyectar `software_requirements/` en sus fases SDD (ver «Skill compañero para gentle-ai»).

`software_requirements/README.md` lista los 5 centrales y el 6 si se creó, con su estado (✅ listo · 🟡 en progreso · ⬜ pendiente), sus `[PENDIENTE]` abiertos, cuántas inconsistencias (INC) se resolvieron y si pasó las 3 rondas de revisión (Fase 4). En entornos sin acceso directo al repositorio, genera los archivos en el área de trabajo y compártelos para que el usuario los descargue a su `software_requirements/`.

## Handoff a gentle-ai

`software_requirements/00-handoff.md` es el **contrato dirigido a agentes** (no al humano): le dice al orquestador de gentle-ai y a sus subagentes de fase qué documento leer, para qué, y qué cambios candidatos existen. Créalo en la Fase 0 **exactamente** con esta plantilla (sustituye solo `<Nombre del producto>`; si el nombre aún no existe en la Fase 0, usa `[PENDIENTE]` y fíjalo cuando el PRD lo defina); el backlog se llena al liberar el catálogo de requisitos (doc 03) y se actualiza al liberar cada documento posterior; su columna «Estado» se mantiene al día siguiendo el «Circuito de retorno» de la plantilla (🟡 al iniciar un cambio, ✅ al archivarlo).

````markdown
# Handoff a gentle-ai — <Nombre del producto>

> **Para agentes SDD** (orquestador de gentle-ai y subagentes de fase): antes de
> explorar el código o redactar una propuesta, lee los documentos de `software_requirements/`
> listados aquí. Son la fuente de verdad de negocio y requisitos de este proyecto;
> la exploración de código no los descubre por sí sola.

## Mapa: qué documento alimenta cada fase

| Fase gentle-ai | Documentos que la alimentan | Qué extraer |
|---|---|---|
| `proposal` | `01-prd.md` + la entrada del backlog de este archivo | Intent, Scope (In/Out), no-objetivos, riesgos, criterios de éxito |
| `spec` | `03-requisitos.md` (RF con intención de aceptación, RFC 2119) + `04-reglas-de-negocio.md` | RF-/RNF- con intención de aceptación y palabras clave RFC 2119; RN- implicadas |
| `design` | `05-modelo-de-dominio.md` (+ `06-modelo-de-datos.md` / `database.dbml` SOLO si existen, como restricción de hecho) + restricciones de negocio del 03 | Entidades, relaciones e invariantes conceptuales; base existente como restricción; restricciones de negocio |
| `tasks` | Backlog de este archivo | Estimación de tamaño del cambio (columna de riesgo de 400 líneas) |
| *(todas)* | `02-glosario.md` | Gobierna el naming en TODAS las fases y artefactos |

> Nota: gentle-ai deriva por cambio el Gherkin (`sdd-spec`), el diseño de agregados
> (`sdd-design`) y el esquema nuevo (`sdd-design`/`sdd-apply`); estos documentos no
> los pre-hacen.

## Regla de extracción

**Extraer, no copiar.** Los artefactos de gentle-ai tienen límites duros de palabras
(proposal <450, spec <650, design <800 palabras). Toma solo lo que el cambio en curso
necesita y referencia los IDs estables (RF-/RNF-/RN-) en vez de reformular el contenido.

## Backlog de cambios candidatos

Cada entrada debe ser una rebanada del tamaño de **un PR**; si una rebanada parece
superar 400 líneas cambiadas, divídela. Estas entradas son insumo listo para
`/sdd-new <cambio>`.

| Cambio candidato | Objetivo | RF/RNF cubiertos | RN implicadas | Riesgo de exceder 400 líneas (Alto/Medio/Bajo) | Dependencias entre cambios | Estado (⬜ pendiente · 🟡 en curso · ✅ archivado) |
|---|---|---|---|---|---|---|
| *(se llena al liberar el catálogo de requisitos, doc 03)* | | | | | | ⬜ |

### Circuito de retorno (medición de progreso)

- Al iniciar un cambio con `/sdd-new`, marcar su fila 🟡.
- Al archivar un cambio (fase `sdd-archive` de gentle-ai), marcar su fila ✅ y
  actualizar las columnas «Intención de aceptación cubierta» y «Estado» de los
  RF-/RNF- cubiertos en la matriz de trazabilidad de `software_requirements/03-requisitos.md`.

Así `software_requirements/` mide el avance del producto contra los requisitos, mientras
gentle-ai mide el cumplimiento por cambio (`sdd-verify`) — alturas distintas,
sin redundancia.
````

## Skill compañero para gentle-ai (software-requirements-context)

El registro de skills de gentle-ai escanea `{raíz-del-proyecto}/skills/`, así que este skill compañero se auto-inyecta en los subagentes de fase SDD (explore, proposal, spec, design, tasks) y hace descubrible `software_requirements/` sin intervención humana.

- En la Fase 0, junto con `00-handoff.md`: si no existe `skills/software-requirements-context/SKILL.md` en la **RAÍZ del proyecto** (fuera de `software_requirements/`), créalo **exactamente** con la plantilla fija de abajo (sustituye solo `<Product name>`; `[PENDIENTE]` permitido).
- Tras crearlo, el registro lo indexa solo: la instalación estándar de gentle-ai refresca el registro en cada prompt (hook `UserPromptSubmit` → `gentle-ai skill-registry refresh`). Si ese hook no está activo en el entorno del usuario, dile que ejecute `gentle-ai skill-registry refresh` (o `/sdd-init` si nunca se corrió).
- La plantilla va **EN INGLÉS** (los artefactos de gentle-ai y el matching de skills usan inglés por defecto):

````markdown
---
name: software-requirements-context
description: 'Foundational product documentation for this project. Trigger: before proposing, specifying, designing, exploring, or breaking down ANY change in this codebase (SDD phases: explore, propose, spec, design, tasks); when business rules, requirements, domain terms, scope, or acceptance criteria are needed. Read software_requirements/00-handoff.md first.'
---

# software-requirements-context — <Product name>

This project keeps human-approved foundational documentation in `software_requirements/`. Those
documents are the source of truth for business intent — requirements, business rules,
domain model, and ubiquitous language. Code exploration cannot discover them.

## How to use

1. Read `software_requirements/00-handoff.md` FIRST — it maps each SDD phase to the documents
   that feed it and lists the candidate-change backlog.
2. Extract only what the change at hand needs, referencing stable IDs (RF-/RNF-/RN-).
   Do NOT restate content: SDD artifacts have hard word limits.
3. The docs may be written in Spanish; produce your artifacts in English as usual,
   using the glossary's "Término en código" column for identifiers.

## Maintenance

After archiving a change (`sdd-archive`), update the backlog Estado in
`software_requirements/00-handoff.md` and the traceability matrix in `software_requirements/03-requisitos.md`
(see "Circuito de retorno" in the handoff).
````

## Cómo invocar (resumen)

1. Usuario: "entrevístame para el PRD" / "documentemos el proyecto".
2. Fase 0: crea/abre `software_requirements/`, lee previos, prepara preguntas derivadas, carga el agente.
3. Fase 1: volcado libre.
4. Fase 2: 30+ preguntas de selección (según documento) (E/A/Q/X) por bloques.
5. Fase 3: redacta, evidencia INC, guarda en `software_requirements/`.
6. Fase 4: panel de revisión (3 rondas × 5 agentes Opus en paralelo) + repreguntas; libera el documento y actualiza el índice.
7. Propón el siguiente documento.
