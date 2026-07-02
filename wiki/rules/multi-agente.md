# Multi-agente

- Una feature = una carpeta = UN agente que la posee de punta a punta: nunca dos agentes editando el mismo slice en paralelo — el radio de daño de un error queda acotado a esa carpeta.
- Repartí el trabajo por features distintas para no pisarte con otro agente: los diffs viven en carpetas disjuntas, y esa capa estructural la impone dependency-cruiser, no la disciplina.
- Cruzá entre features SOLO por `public.ts`: nunca alcances los internos del slice que posee otro agente.
- Cortá tu rama como `feature/<nombre>` desde `develop` y volvé por PR con los gates verdes; mantené la rama CORTA e integrá temprano y seguido — una rama que vive semanas acumula un diff gigante y el merge se vuelve el punto de dolor que el slice había evitado.
- No cueles cambios a `src/core/` o `src/shared/` en el PR de una feature: tocan a todas las features a la vez, así que van como cambio propio y coordinado, con su propia rama y PR.
- Tratá el handoff entre fases como un artefacto explícito, no conocimiento tácito: el puerto en `ports.ts` y el contrato OpenAPI fijan la interfaz en la fase de diseño para que otra fase (u otro agente) la cumpla sin releer todo.
- El estado compartido vive en artefactos —la wiki, `openspec/`, la memoria persistente—, nunca en la conversación de un solo agente: registrá decisiones, bugs y convenciones donde el próximo agente pueda encontrarlos.

Doctrina: wiki/proceso/01_explicacion-trabajo-con-ia.md
