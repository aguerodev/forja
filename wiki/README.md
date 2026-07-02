# Wiki de la doctrina forja

Esta wiki viaja **dentro del plugin forja** (repo `aguerodev/forja`): los proyectos no la copian, la consultan vía la skill `forja:doctrina`.

El punto de entrada es **[MANIFIESTO.md](./MANIFIESTO.md)**: el mapa derivado de la wiki (tiers, DAG, índice de temas y recetas por tarea).

Humanos: empezá por `fundamentos/` y bajá por tiers según lo que necesites. Agentes: leé el protocolo para sesión fresca al inicio del MANIFIESTO y cargá la receta de tu tarea.

El gate del grafo (`node wiki/_meta/validate-graph.mjs --check`) corre en el CI del repo del plugin; los proyectos consumidores no lo ejecutan.
