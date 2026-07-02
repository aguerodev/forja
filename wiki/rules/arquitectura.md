# Arquitectura

- El dominio puro es innegociable: `domain.ts` y `ports.ts` solo importan su propio dominio, `@/core/errors` y `@/shared` puro (allowlist) — nada de Next, Drizzle, `pg`, Zod, SDKs ni builtins con I/O.
- Organizá por vertical slices con núcleo hexagonal: una feature = una carpeta autocontenida bajo `src/features/<feature>/`.
- Cruzá entre features SOLO por `public.ts`: los internos de otra feature quedan sellados.
- Pasá toda integración de tercero por un puerto (declarado en `ports.ts`) + adaptador (`<provider>.adapter.ts`) que consume el cliente `core/http` — el contrato `egress-through-httpclient` prohíbe primitivas de red crudas fuera de `src/core/http`.
- Traducí todo error de proveedor a un `DomainError` en el adaptador: el SDK, la firma y los tipos del proveedor nunca salen del adaptador.
- Los contratos de dependency-cruiser no se negocian: si `depcruise` falla, corregí el diseño, nunca el linter.

Doctrina: wiki/arquitectura/03_referencia-convenciones-codigo.md, wiki/arquitectura/07_referencia-gates-tooling.md
