# Agentes de revisión: Panel Opus (gate de calidad)

**Propósito:** ningún documento se libera sin pasar **3 rondas** de revisión por **5 agentes** que, de forma **independiente y en paralelo**, buscan inconsistencias, ambigüedades, omisiones y riesgos. Tras cada ronda de críticas hay un **ciclo de repregunta** para decidir y aplicar ajustes.

Esto es la **Fase 4** del protocolo y es complementario a las preguntas X de la Fase 2: aquéllas cazan conflictos *mientras* se recoge la información; el panel revisa el *documento terminado* de forma independiente, con la mirada fresca de cinco críticos.

## Cuándo se ejecuta
Después de la Fase 3 (borrador) de **cualquier** documento (1–5, y 6 si se creó) y **antes** de marcarlo como liberado en `software_requirements/README.md`. El 06, cuando se crea, pasa igualmente este gate.

## Los 5 revisores (lentes)
Cada revisor usa el **modelo Opus**, recibe el borrador + los documentos previos de `software_requirements/` + el archivo-agente del documento (como rúbrica) y entrega sus hallazgos **sin ver los de los demás** (independencia). Cada uno, dentro de su lente, también marca inconsistencias y ambigüedades.

- **R1 — Consistencia y trazabilidad.** Contradicciones internas y contra los documentos previos (PRD, glosario, catálogo de requisitos, reglas, dominio). Verifica que los IDs (RF-/RNF-/RN-) se referencien bien y que el vocabulario sea el del glosario. Verifica también que el «Backlog de cambios candidatos» de `software_requirements/00-handoff.md` se mantenga consistente con los IDs RF-/RNF-/RN- liberados (sin referencias huérfanas ni requisitos liberados sin cambio candidato que los cubra).
- **R2 — Ambigüedad y testabilidad.** Frases vagas o interpretables de varias formas; requisitos/reglas que no son atómicos ni verificables; criterios de aceptación faltantes o no medibles. Pregunta: "¿una IA programaría esto de una sola manera?". Verifica además que los RF/RNF usen palabras clave RFC 2119 (MUST/SHOULD/MAY) y que los criterios de éxito sean medibles como checkboxes (`- [ ] métrica alcanza X para fecha Y`).
- **R3 — Completitud y casos borde.** Huecos, casos borde no cubiertos, estados o transiciones faltantes, errores no contemplados, restricciones de negocio (RNF de negocio) ausentes — los NFR de ingeniería son territorio de gentle-ai, no omisiones.
- **R4 — Factibilidad técnica y riesgos (mirada de IA implementadora).** ¿Qué confundiría o haría fallar a quien lo programe? Realismo de los RNF, riesgos de arquitectura, seguridad y PII, decisiones que se contradicen con la realidad técnica.
- **R5 — Negocio, alcance y cumplimiento.** Alineación con objetivos y no-objetivos del PRD, scope creep, solidez de las reglas de negocio, requisitos legales/regulatorios.

## Cómo ejecutarlos (independiente y en paralelo)
- **Claude Code / Cowork:** lanza los 5 como **subagentes en paralelo en el mismo turno**, cada uno con el **modelo Opus** y una de las 5 lentes. No comparten contexto entre sí hasta la consolidación.
- **claude.ai (sin subagentes):** adopta las 5 lentes **una por una** sobre el mismo borrador; no mires tus conclusiones anteriores hasta terminar las cinco, y luego consolida. Es menos independiente, pero sigue siendo un gate útil.

## Formato de cada hallazgo
Cada revisor entrega una lista; cada hallazgo:
- **ID:** `R{n}-{k}` (p. ej. R2-3)
- **Tipo:** Inconsistencia | Ambigüedad | Omisión | Riesgo | Mejora
- **Severidad:** Alta | Media | Baja
- **Ubicación:** sección o ID afectado (p. ej. RF-007, tabla `pedido`)
- **Descripción:** qué está mal y por qué
- **Resolución sugerida**
- **Opciones para el usuario** (para la repregunta)

## Consolidación
Une los 5 informes, **deduplica** (varios revisores pueden ver lo mismo), **ordena por severidad** y agrupa por sección. Resume cuántos hallazgos hay por tipo y severidad antes de repreguntar.

## Ciclo de repregunta (tras cada ronda)
Por cada hallazgo que requiera una decisión, formula una **repregunta de selección** (única o múltiple), con opciones que incluyan **siempre** "Otro (lo escribo)" y "Dejarlo como está (con justificación)". Hazlas por bloques, priorizando severidad Alta. Aplica las decisiones al borrador. Cada **inconsistencia** resuelta se registra como `INC-xx` en el documento.

## Bucle de 3 rondas
Repite **[5 críticas en paralelo → consolidar → repreguntar → ajustar]** tres veces. En la ronda N, los revisores evalúan el borrador **ya ajustado** en la ronda N-1 y se enfocan en: (a) si los ajustes introdujeron nuevos problemas y (b) lo que quede pendiente. Una ronda puede cerrar "sin hallazgos nuevos de severidad alta" — sigue contando como ronda.

## Criterio de liberación (release gate)
Libera el documento cuando: se **completaron las 3 rondas** Y **no quedan hallazgos de severidad Alta sin resolver**. Los de severidad Baja pueden quedar como `[PENDIENTE]` documentado. Entonces marca ✅ en `software_requirements/README.md` (con las 3 rondas registradas) y guarda la bitácora.

## Bitácora de revisión
Guarda en `software_requirements/review/<NN-doc>.review.md`: por cada ronda, los hallazgos consolidados y su resolución (o por qué se dejaron como estaban). El documento liberado lleva una línea al inicio: `Estado de revisión: ✅ 3 rondas completadas (ver software_requirements/review/<NN-doc>.review.md)`.

## Rúbrica por documento (qué priorizar)
- **PRD:** objetivos medibles, no-objetivos explícitos, alcance coherente con tiempo y presupuesto.
- **Glosario:** un término por concepto, sinónimos prohibidos, sin choques de significado, nomenclatura consistente.
- **Catálogo de requisitos (doc 03-requisitos):** claridad a nivel capacidad, requisitos atómicos con intención de aceptación, restricciones de negocio puras (NFR de ingeniería o Gherkin exhaustivo = scope creep), sin requisitos mutuamente excluyentes, trazabilidad a fuente.
- **Reglas de negocio:** atómicas y numeradas, trazables a RF/RNF, sin reglas en conflicto, fórmulas con redondeo y unidades del glosario.
- **Modelo de dominio:** se mantiene conceptual (diseño de agregados/persistencia = scope creep), invariantes ↔ RN con excepciones de negocio explícitas, nombres del glosario, eventos como hechos de negocio, relaciones con cardinalidades claras.
- **Modelo de datos (opcional, solo brownfield):** documenta lo existente como hecho (DISEÑAR esquema nuevo greenfield = scope creep), DBML válido y fiel a la base real, PII y protección actual explícitas, brechas frente a dominio/reglas documentadas, mapeo de nombres actual↔glosario.
