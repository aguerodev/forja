---
id: proc.requerimientos
titulo: Generar los documentos de requerimientos (spec-doc-interviewer)
tipo: how-to
tier: 1
audience: both
resumen: El paso 0 del desarrollo — generar por entrevista los documentos de requerimientos que alimentan el flujo SDD, antes de escribir código.
provides:
  - "entrevista de especificación por selección"
  - "volcado libre"
  - "cuatro tipos de pregunta E/A/Q/X (exploratoria, aclaratoria, de calidad, de contradicción)"
  - "opción de escape"
  - "pregunta de calidad con recomendación (estrella)"
  - "pregunta de contradicción"
  - "las cuatro fases del interviewer (arranque, volcado, entrevista, redacción)"
  - "panel de revisión 3x5 (tres rondas, cinco lentes)"
  - "las cinco lentes del panel de revisión"
  - "marcas [SUPUESTO] / [PENDIENTE] / [DECISIÓN ABIERTA]"
reads-before: [proc.sdd]
related: []
---

# Cómo generar los documentos de requerimientos con spec-doc-interviewer

Antes de diseñar ni escribir una línea de código, el proyecto fija **qué construir, para quién y bajo qué reglas**. Ese es el paso 0 del desarrollo: una entrevista estructurada que produce la carpeta `software_requirements/`, la base de verdad de requerimientos y el insumo de entrada del flujo SDD. El skill `spec-doc-interviewer` conduce esa entrevista. Qué es SDD, qué hace Gentle AI y la estructura de carpeta de `software_requirements/` están en [SDD, flujo de especificación y Gentle AI](./03_explicacion-sdd.md); este documento describe **cómo se generan** esos requerimientos.

## Cuándo se usa

Una sola vez al arrancar un proyecto, antes de [diseñar la interfaz y de implementar](./04_how-to-arrancar-proyecto-nuevo.md). La salida `software_requirements/` es estable —evoluciona poco— y abre la cadena `software_requirements/ -> claude_design/ -> openspec/ -> src/`. Sin `software_requirements/` no hay insumo para que Gentle AI inicie el SDD.

## Qué produce: la cadena de seis documentos

El skill construye seis documentos **en este orden**, cada uno con su agente especializado, más los artefactos de soporte:

1. **PRD** — el porqué y para quién.
2. **Glosario (lenguaje ubicuo)** — un término por concepto; el vocabulario único que heredan los demás.
3. **Catálogo de requisitos** (SRS ligero, a nivel capacidad) — qué debe hacer el sistema (requisitos `RF-`/`RNF-`).
4. **Catálogo de reglas de negocio** — políticas e invariantes (`RN-`).
5. **Modelo de dominio** — entidades y relaciones (Mermaid `classDiagram`).
6. **Modelo de datos** — SOLO brownfield u orden explícita: la base existente como restricción, en DBML publicado con dbdocs.

Artefactos de soporte: `software_requirements/README.md` (índice de estado por documento: ✅ listo · 🟡 en progreso · ⬜ pendiente, con sus pendientes abiertos, inconsistencias resueltas y rondas de revisión cumplidas), `database.dbml` (solo brownfield: el esquema existente en DBML, se publica con dbdocs) y `review/` (una bitácora del panel de revisión por documento). El identificador `INC-` marca cada inconsistencia detectada y su resolución. El árbol completo de la carpeta está en [SDD, flujo de especificación y Gentle AI](./03_explicacion-sdd.md#software_requirements--los-requerimientos).

### La cadena de dependencias

Los seis documentos forman una cadena, no una lista. Cada documento **hereda el vocabulario del glosario** y se construye sobre los previos: el catálogo de requisitos, las reglas, el dominio y el modelo de datos usan exactamente los términos del glosario (si hace falta uno nuevo, se agrega allí); el modelo de dominio se levanta sobre las entidades del catálogo y las reglas; el modelo de datos realiza el dominio en persistencia. La consecuencia operativa: **cada etapa genera preguntas nuevas derivadas de los documentos ya redactados**. Antes de empezar cualquier documento que no sea el primero, el skill lee de `software_requirements/` lo ya escrito y, a partir de eso, fabrica preguntas específicas —aclaratorias, de calidad y de contradicción— además de su banco base. Esa retroalimentación hace que cada etapa pregunte mejor que la anterior.

## El protocolo de fases por documento

Cada documento se redacta atravesando las mismas cuatro fases. Ninguna se omite.

### Fase 0 — Arranque

Si `software_requirements/` no existe, se crea junto con su `README.md`. Se confirma qué documento se trabaja (de cero, se recomienda el orden 1 → 5; el 06-modelo-de-datos se genera SOLO en brownfield —documenta una base existente— o por orden explícita del usuario). Para los documentos 2–6 se **leen primero los previos** y, a partir de ellos, se preparan preguntas derivadas (A/Q/X específicas) antes de empezar. Se carga el agente del documento en cuestión.

### Fase 1 — Volcado libre

El usuario escribe con sus palabras **todo lo que sabe**, sin orden ni filtro y **sin interrupciones**. No se dispara ninguna pregunta todavía. Si escribe poco, se lo anima con una o dos preguntas abiertas. El volcado es la materia prima que las preguntas posteriores afinan.

### Fase 2 — Entrevista de especificación por selección (50+ preguntas)

El núcleo del skill. **Todas las preguntas son de selección** —el usuario responde tocando opciones, no redactando ensayos— en modo **U (única)** o **M (múltiple)**, lanzadas por bloques temáticos de 5–8, no todas de golpe. Cada pregunta termina con una **opción de escape**: la última opción siempre permite salir ("Otro, lo escribo" o "No lo sé aún → [PENDIENTE]"), de modo que nada se pierde ni nadie queda forzado.

Cada pregunta es de uno de **cuatro tipos**:

- **E — Exploratoria**: descubre qué existe, abre territorio nuevo.
- **A — Aclaratoria**: precisa o desambigua algo ya dicho, o algo vago en un documento previo.
- **Q — De calidad**: propone una decisión de diseño con la opción **recomendada marcada (★)** y un porqué de una línea. No solo recoge información: empuja la mejor práctica.
- **X — De contradicción / consistencia**: confronta respuestas entre sí o contra los documentos previos para cazar conflictos. Cuando aparece uno, se formula una pregunta de selección única con las opciones en conflicto para que el usuario decida, y la resolución se registra como `INC-xx`.

Las opciones de los bancos son plantillas: se adaptan al dominio del usuario y se rellenan con lo que salió del volcado y de los documentos previos. Si el volcado ya respondió algo, no se repite: se confirma o se pide precisión.

### Fase 3 — Redacción

Se redacta el documento con la plantilla del agente y el vocabulario del glosario. Lo no resuelto se marca explícitamente: `[SUPUESTO: …]` (se asumió algo), `[PENDIENTE: …]` (falta definir), `[DECISIÓN ABIERTA: A / B]` (hay opciones sin elegir). Se asignan **identificadores trazables** (`RF-`/`RNF-`, `RN-`, `INC-`) y se citan derivaciones (p. ej. una regla `RN-` responde a un requisito `RF-`). El documento incluye SIEMPRE una sección **`## Inconsistencias detectadas y su resolución`** con las entradas `INC-xx` (conflicto, fuentes enfrentadas, decisión tomada) y una marca inline `[INC-xx]` donde la decisión resolvió el conflicto. Se guarda en `software_requirements/` y se actualiza el `README.md`.

### Fase 4 — Panel de revisión (3 rondas × 5 lentes)

Ningún documento se libera sin pasar este gate. El borrador se somete a **cinco revisores que trabajan de forma independiente y en paralelo**, cada uno con una **lente distinta**:

1. **Consistencia / trazabilidad** — IDs coherentes, derivaciones que cierran.
2. **Ambigüedad / testabilidad** — cada afirmación verificable, sin frases vagas.
3. **Completitud / casos borde** — qué falta, qué escenario no se contempló.
4. **Factibilidad técnica** — si lo especificado se puede construir.
5. **Negocio / alcance** — coherencia con el PRD, sin scope creep.

Tras cada ronda se **consolidan los cinco informes y se convierten los hallazgos en repreguntas de selección** (U/M) para que el usuario decida; los ajustes se aplican al borrador y las nuevas inconsistencias se registran como `INC-xx`. El ciclo se repite **tres rondas**. El documento se **libera solo cuando se completaron las tres rondas y no quedan hallazgos de severidad Alta sin resolver**. La bitácora de cada documento queda en `software_requirements/review/<NN-doc>.review.md`. El panel complementa —no reemplaza— a las preguntas X de la Fase 2: las X cazan conflictos mientras se recoge la información; el panel revisa el documento terminado con criterio independiente.

Liberado el documento, se resume lo capturado, se listan sus pendientes e inconsistencias, se marca ✅ en el `README.md` y se propone el siguiente documento de la cadena.

## Reglas de calidad transversales

Aplican a las cuatro fases de los seis documentos:

- **No inventar.** Si no se sabe, se marca `[PENDIENTE]` o `[SUPUESTO]`; nunca se rellena con suposiciones tácitas.
- **Atómico y verificable.** Una afirmación comprobable por requisito o regla; si mezcla varias cosas, se separa.
- **Trazabilidad por IDs.** Todo lleva identificador (`RF-`/`RNF-`, `RN-`, `INC-`) y cita sus derivaciones.
- **Evidenciar contradicciones.** Un conflicto nunca se "arregla" en silencio: se registra en la sección de inconsistencias con su origen y su resolución.
- **Coherencia de lenguaje.** Mismo término para la misma cosa, alineado al glosario; un concepto nuevo entra primero al glosario.
- **El usuario manda el ritmo.** Si quiere ir rápido, se agrupan preguntas; si quiere pausar, se guarda el avance parcial en `software_requirements/`.

## Dónde encaja en el flujo

Esta entrevista es el primer eslabón de la cadena de artefactos del proyecto:

```
spec-doc-interviewer  ->  software_requirements/  ->  claude_design/  ->  Gentle AI / SDD  ->  openspec/  ->  src/
   (este documento)          requerimientos             propuesta UI        proceso SDD       specs/cambio   código
```

`software_requirements/` es la base de verdad de requerimientos; junto con `claude_design/` es uno de los dos insumos que Gentle AI recibe al arrancar el SDD. La cadena completa, su trazabilidad de punta a punta por los identificadores `RF-`/`RNF-`/`RN-` y el rol de Gentle AI están en [SDD, flujo de especificación y Gentle AI](./03_explicacion-sdd.md). El procedimiento de arranque de proyecto que enmarca este paso está en [Arrancar un proyecto nuevo](./04_how-to-arrancar-proyecto-nuevo.md).
