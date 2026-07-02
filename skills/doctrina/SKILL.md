---
name: doctrina
description: 'Consultar la doctrina de ingeniería forja - arquitectura hexagonal y vertical slices, convenciones de código, testing y gates, Gitflow, deploy a Swarm, secretos, backups, aprovisionar y operar el servidor Hetzner, rollback, arrancar un proyecto nuevo. Usala siempre que vayas a crear una feature, tocar auth, desplegar, operar el servidor o citar una convención del equipo. Keywords: architecture doctrine, engineering conventions, hexagonal, deploy, Hetzner, Gitflow.'
---

# Doctrina forja

La doctrina completa vive en `${CLAUDE_PLUGIN_ROOT}/wiki/` — 28 documentos en 4 tiers (Fundamentos, Proceso, Arquitectura, Operaciones). **NO leas la wiki entera**: está diseñada para cargarse por recetas.

## Protocolo de consulta

1. Leé `${CLAUDE_PLUGIN_ROOT}/wiki/MANIFIESTO.md`. Es el índice derivado de toda la doctrina: tiers, DAG de lectura (`reads-before`), índice tema → doc dueño, y **recetas por tarea**:
   - `nueva-feature` — crear un slice nuevo
   - `tocar-auth` — cualquier cambio en autenticación o sesión
   - `desplegar` — release a preview o production
   - `rollback` — volver a una versión sana
   - `arrancar-proyecto` — bootstrap de un proyecto desde cero
   - `operar-servidor` — aprovisionar, endurecer o gestionar la infra Hetzner

2. Si tu tarea matchea una receta → leé **exactamente su clausura de docs, en orden** (tier 0 primero). La receta es el cierre de dependencias que necesitás; ni un doc más, ni uno menos.

3. Si NO matchea ninguna receta → usá el **índice tema → doc dueño** del MANIFIESTO para saltar al documento canónico del término (por ejemplo: "expand/contract" → doc dueño de migraciones). No adivines el archivo.

4. **Tier 0 (`wiki/fundamentos/`) se lee SIEMPRE** que arranques trabajo sustancial: ahí viven el dial (complejidad diferida), las tres rectoras y el stack. Es el piso conceptual del que cuelga todo lo demás.

## Reglas duras

- El MANIFIESTO es un **artefacto derivado**: NUNCA lo edites a mano. Lo regenera `node wiki/_meta/validate-graph.mjs --write` y el gate `--check` corre en el CI del plugin.
- La doctrina se edita SOLO en el repo del plugin (`aguerodev/forja`) — nunca en una copia local del proyecto. No hay copias por proyecto que mantener sincronizadas.
- Si el proyecto contradice la doctrina, hay exactamente dos salidas: **la doctrina gana**, o se propone cambiarla con un PR al repo del plugin. Ignorarla en silencio no es una opción — el drift silencioso es cómo se pudre una base de código.

## Cuándo consultarla

- Antes de crear una feature (receta `nueva-feature` — el hexágono del slice tiene forma canónica).
- Antes de tocar auth o sesión (receta `tocar-auth` — es superficie de seguridad).
- Antes de desplegar u operar el servidor (recetas `desplegar` / `operar-servidor` — los controles son exit codes, no prosa).
- Cada vez que cites una convención del equipo: citá el doc dueño, no tu memoria.
