---
id: arq.estructura-repo
titulo: Estructura del repositorio
tipo: referencia
tier: 2
audience: both
resumen: Árbol canónico del repositorio con la responsabilidad de cada carpeta y archivo y las convenciones estructurales clave.
provides:
  - "árbol canónico del repositorio"
  - "src/ (raíz del código importable), src/app/ (cableado fino al framework), src/core/, src/features/, src/shared/, tests/, e2e/"
  - "los tres significados de \"app\""
  - "carpeta secrets/ como convención de ubicación (y secrets/<env>.env en .gitignore)"
  - "slice canónico = nueve archivos de implementación + public.ts (la lista estructural; components/ opcional, composition.ts solo por dial)"
  - "src/components/ui/ (primitivas globales) vs features/<feature>/components/ (específicas de feature)"
  - "tabla != schemas (modelo de persistencia vs contrato del borde)"
  - "ubicación en el árbol de AGENTS.md, drizzle.config.ts y stack.yml"
  - "<provider>.adapter.ts (adaptador de EGRESO, uno por proveedor; canonización del casillero por la regla de tres)"
  - "processed_events (inbox de idempotencia de webhooks; PK compuesta proveedor/origen + event_id; columna attempts para dead-letter)"
reads-before: [arq.hexagonal]
related: [ops.secretos]
---

# Referencia de la estructura del repositorio

El árbol de carpetas y la responsabilidad de cada entrada. El porqué de esta organización —monolito modular, vertical slices, núcleo hexagonal— está en [Arquitectura hexagonal](./01_explicacion-arquitectura-hexagonal.md); esta página solo lista la forma.

## El paquete raíz: `src`, no `app`

El código importable vive bajo **`src/`** (no `app/`). El árbol de routing de Next.js App Router vive dentro, en `src/app/`, y contiene **solo** bindings finos al framework: `src/app/api/<feature>/route.ts` reexporta los handlers del slice, los Server Components leen llamando a las funciones del service de la feature, y los forms invocan los `actions.ts` para mutar. Toda la lógica vive en `src/features/<feature>/`. Tres cosas distintas comparten el nombre "app":

| "app" | Qué es | Cómo se nombra |
|---|---|---|
| Servicio Docker | El contenedor de la aplicación en el Swarm | `app` (alias de red de la overlay) |
| Árbol de routing de Next | El filesystem que el App Router enruta (habilitado por la convención `src/app`) | `src/app/` |
| Código importable | El paquete con toda la lógica de las features | `src/` |

El servidor (`next start`) sirve `src/app/`, pero ninguna feature pone su lógica ahí: el hexágono completo de cada feature queda en una sola carpeta bajo `src/features/`, testeable en aislamiento, sin que la convención de filesystem de Next fragmente el dominio.

## Árbol del repositorio

```text
<repo>/
├── src/                              # raíz del código importable
│   ├── app/                          # Next.js App Router: SOLO routing/binding al framework, sin lógica
│   │   ├── layout.tsx
│   │   ├── page.tsx
│   │   ├── api/
│   │   │   ├── <feature>/
│   │   │   │   └── route.ts          # binding fino: `export { GET, POST } from "@/features/<feature>/route"`
│   │   │   └── openapi/
│   │   │       └── route.ts          # sirve el OpenAPI 3.1 generado por zod-to-openapi (insumo de Schemathesis)
│   │   └── <feature>/
│   │       └── page.tsx              # Server Component; LEE llamando a la función del service: listMyLinks(actor)
│   ├── core/                         # módulos transversales: config, errors, authz, auth, db, http, observability
│   │   ├── config.ts                 # server-only: getConfig(): Zod + /run/secrets (contrato: secret = campo)
│   │   ├── errors.ts                 # DomainError base + jerarquía de errores de dominio
│   │   ├── authz.ts                  # Actor + requirePermission, deny-by-default (la guarda se APLICA en use-cases.ts)
│   │   ├── auth/                      # Better Auth: sesiones en Postgres, email/password + OAuth; deriva el Actor server-side
│   │   │   ├── config.ts             # server-only: instancia Better Auth (cookie HttpOnly+Secure+SameSite=Lax, rotación)
│   │   │   └── actor.ts              # server-only: getActor() desde la sesión verificada (nunca de body/headers/params)
│   │   ├── openapi.ts                # OpenApiRegistry + generador del documento OpenAPI 3.1
│   │   ├── db/
│   │   │   ├── client.ts             # server-only: Pool (pg) + drizzle(); getDb()
│   │   │   └── migrations/           # salida versionada de drizzle-kit
│   │   ├── http/
│   │   │   ├── errors.ts             # DomainError → Response: ÚNICA traducción HTTP
│   │   │   ├── actor.ts              # actorFromRequest(): extrae el Actor del request
│   │   │   └── client.ts             # server-only: puerto HttpClient compartido (borde de EGRESO): `timeout` como parámetro REQUERIDO de la firma (tsc rompe si falta) + hook de validación host/IP anti-SSRF
│   │   └── observability/
│   │       ├── logger.ts             # pino
│   │       └── sentry.ts             # @sentry/nextjs
│   ├── shared/                       # primitivas de dominio compartidas (CON MODERACIÓN)
│   └── features/                     # vertical slices: un módulo por contexto de negocio
│       └── <feature>/                # un slice = hexágono completo en una carpeta
│           ├── domain.ts             # PURO: entidad + invariante + errores de dominio de la feature
│           ├── ports.ts              # PURO: puerto que la feature necesita del exterior (p. ej. <Feature>Repository)
│           ├── use-cases.ts          # PURO: casos de uso + autorización (deny-by-default antes de mutar); puerto y deps no deterministas POR ARGUMENTO
│           ├── service.ts            # server-only: punto de composición y fachada; pre-cablea el adaptador concreto en los use cases; lo ÚNICO que importa el borde
│           ├── schemas.ts            # Zod I/O + .openapi() — contrato de la API externa (route.ts)
│           ├── table.ts              # tabla(s) Drizzle; SOLO si persiste. La columna 'version' (optimistic locking) es DIAL: entra cuando hay escritura concurrente real sobre el mismo agregado. La feature que recibe webhooks declara aquí su tabla `processed_events` (PK COMPUESTA: proveedor/origen + event_id, NUNCA event_id solo; columna `attempts`): inbox de idempotencia para entregas at-least-once. Nace CON esa primera feature, no pre-creada vacía
│           ├── repository.ts         # server-only: adaptador Drizzle del puerto de PERSISTENCIA; traduce pg → dominio
│           ├── <provider>.adapter.ts # server-only: adaptador de EGRESO (1 por proveedor de tercero); implementa un puerto de ports.ts sobre core/http/client.ts; el SDK/firma del proveedor NO sale de aquí; traduce provider → DomainError. SOLO si el slice llama a un tercero. Con un único proveedor el seam es solo la interface en ports.ts; el casillero se canoniza (regex en dependency-cruiser + rama de Plop + espejo de test) recién con el SEGUNDO adaptador real
│           ├── route.ts              # API externa: Route Handlers (GET/POST/...) → contrato OpenAPI + Schemathesis
│           ├── actions.ts            # Server Actions ("use server"): MUTACIÓN desde forms/eventos; revalidatePath + estado serializable
│           ├── composition.ts        # DIAL, no base: se extrae recién cuando hay transacción multi-repo (withTransaction) o segunda implementación de un puerto
│           ├── public.ts             # superficie pública: ÚNICO archivo importable por otra feature (tipos + interfaz del service)
│           └── components/           # OPCIONAL: presentación propia de la feature cuando crece; lo genérico vive en src/components/ui
├── tests/                            # separado por PROYECTO de Vitest, espejando src/ adentro de cada uno
│   ├── unit/                         # lo que corre `pnpm run check` (sin I/O, milisegundos)
│   │   └── features/<feature>/
│   │       ├── domain.test.ts        # invariantes con Vitest + fast-check, sin I/O
│   │       └── use-cases.test.ts     # casos de uso con fake del puerto; tests NEGATIVOS de autorización
│   └── integration/                  # lo que corre `pnpm test:integration` (testcontainers)
│       └── features/<feature>/
│           ├── repository.test.ts    # adaptador de persistencia contra Postgres efímero (testcontainers-node)
│           └── <provider>.adapter.test.ts # espejo del adaptador de EGRESO: parseo, traducción provider → DomainError, timeout. SOLO si el slice tiene <provider>.adapter.ts
├── e2e/                              # Playwright (flujos críticos)
├── drizzle.config.ts                # schema: "./src/features/**/table.ts" (slices verticales, migración central)
├── biome.json                       # lint + format (un binario)
├── .dependency-cruiser.cjs          # contratos ejecutables: dominio puro (forbidden) + features independientes (cruce solo vía public.ts) + egreso solo vía core/http (egress-through-httpclient)
├── vitest.config.ts
├── tsconfig.json                    # strict; paths { "@/*": ["./src/*"] }
├── next.config.ts
├── package.json                     # scripts; "check" corre TODOS los gates (local = CI)
├── pnpm-lock.yaml                    # versiones exactas
├── Dockerfile                       # Node multi-stage
├── stack.yml                        # stack Swarm: app + db + cloudflared
├── secrets/                         # <env>.env (gitignored) → Docker secrets
│   └── <env>.env
└── AGENTS.md
```

> Una feature sin persistencia (in-memory) OMITE `table.ts`, y su `repository.ts` implementa el puerto con un `Map` en memoria en vez de Drizzle. Una feature que no llama a ningún tercero OMITE `<provider>.adapter.ts` (y su espejo de test). **La misma condicionalidad rige el borde**: `route.ts` existe SOLO si la feature expone API externa o webhooks (sin consumidor externo no hay superficie OpenAPI que fuzzear); `actions.ts` SOLO si tiene mutaciones desde UI; `domain.ts` según la regla de modelado de [Convenciones](./03_referencia-convenciones-codigo.md). El árbol de arriba muestra el slice canónico COMPLETO; cada archivo condicional aparece SOLO cuando su responsabilidad existe.

## Notas

- **El slice canónico son 9 archivos de implementación** (`domain.ts`, `ports.ts`, `use-cases.ts`, `service.ts`, `schemas.ts`, `table.ts`, `repository.ts`, `route.ts`, `actions.ts`), más el `public.ts` (superficie pública del contrato cross-feature). Condicionales: `<provider>.adapter.ts` (solo si el slice llama a un tercero), `components/` (solo cuando la feature acumula presentación propia; lo genérico vive en `src/components/ui/`) y `composition.ts` (**dial**: se extrae recién ante transacción multi-repo o segunda implementación de un puerto — hasta ahí, el punto de composición es `service.ts`). Ese es el único patrón que sigue toda feature.
- **`public.ts` es el contrato entre features.** El ÚNICO archivo que otra feature puede importar: reexporta los tipos del dominio que cruzan la frontera y la **interfaz** del servicio, nunca internos (`domain`, `repository`, `table`, `composition` quedan privados). dependency-cruiser exime SOLO este archivo del gate de independencia; cualquier otro import cross-feature rompe el build.
- **`features/<feature>/components/` aloja la presentación de la feature.** Los componentes React (server/client) PROPIOS del contexto de negocio viven dentro del slice, no dispersos. `src/components/ui/` global queda reservado a primitivas genéricas reutilizables (shadcn). Regla: genérico → `src/components/ui/`; específico de feature → `features/<feature>/components/`.
- **`server-only` marca los módulos que jamás deben llegar al cliente.** `core/config.ts`, `core/db/client.ts`, y dentro de cada slice `service.ts` y `repository.ts` (y `composition.ts` cuando el dial lo trajo) importan `server-only` en el tope: si una cadena de imports desde un componente `"use client"` los alcanza, el build cae antes de filtrar secretos o el pool de `pg` al bundle del navegador.
- **`<provider>.adapter.ts` nombra el hogar del adaptador de EGRESO, pero la canonización sigue la regla de tres.** Vive junto a `repository.ts` (ambos son adaptadores: uno de persistencia, otro de salida a un tercero). Hay un archivo por proveedor (`stripe.adapter.ts`, `resend.adapter.ts`), cada uno implementa un puerto declarado en `ports.ts` y se apoya en el `HttpClient` compartido de `core/http/client.ts`. El SDK o la firma del proveedor JAMÁS escapa del adaptador: el dominio puro queda intacto y el cambio de proveedor A→B toca un solo archivo. Pero **nombrar un casillero NO es generar su scaffolding**: con un único proveedor, el seam es solo la interface declarada en `ports.ts`; el casillero se canoniza —regex propia en dependency-cruiser, rama del generador de Plop y espejo de test en `tests/integration/features/<feature>/<provider>.adapter.test.ts` (una ruta fuera de `tests/unit/` o `tests/integration/` no la corre ningún proyecto de Vitest)— recién tras la SEGUNDA ocurrencia real en el repo.
- **El borde de EGRESO se monta sobre `core/http/client.ts`.** Es el puerto `HttpClient` compartido para TODA llamada saliente a terceros. Dos controles viajan en el seam: `timeout` es un parámetro REQUERIDO de la firma (no un default de runtime: si falta, `tsc` rompe el build) y el cliente EXPONE un hook de validación de host/IP anti-SSRF; la política completa del hook (disparador por origen de la URL, pinning de IP, redirects, rangos bloqueados) es normativa en [Convenciones](./03_referencia-convenciones-codigo.md#el-borde-de-egreso-el-puerto-httpclient). El `idempotencyKey` NO vive en este puerto genérico: es parámetro de la operación específica del `<provider>.adapter.ts` (header `Idempotency-Key`), no del transporte. Los adaptadores lo consumen; ningún slice abre `fetch` crudo por su cuenta —el contrato `egress-through-httpclient` de dependency-cruiser lo prohíbe como GATE—. Es el cuarto camino del borde, el SALIENTE (ver la nota "Cuatro caminos en el borde").
- **`processed_events` es el inbox de idempotencia de webhooks.** Su PK es COMPUESTA: proveedor/origen + `event_id`, NUNCA `event_id` solo —dos proveedores pueden emitir el mismo id y una PK simple causaría falso dedupe entre ellos—. La deduplicación de entregas at-least-once se hace con `INSERT ... ON CONFLICT DO NOTHING`, que debe correr DENTRO de la `withTransaction` de la mutación para que dedupe y cambio de estado commiteen juntos, atómicos. Lleva además una columna `attempts` que habilita la ruta de dead-letter y la política de poda ante eventos veneno. La tabla NO se pre-crea vacía: nace CON la primera feature que recibe un webhook, en su `table.ts` (queda dentro del glob `features/**/table.ts` que arma las migraciones). Si la dedupe es transversal a varias features, se promueve a un `table.ts` compartido cuya ruta debe incluirse explícitamente en el `schema` de `drizzle.config.ts`. El webhook ya procesado responde 200 (no 409): el reflejo `conflict`→409 del optimistic locking es para escrituras concurrentes sobre el mismo agregado, no para un evento repetido.
- **`tests/` espeja `src/features/`.** Por cada `src/features/<feature>/` hay un `tests/<feature>/`, con un archivo por capa (`domain.test.ts`, `service.test.ts`, `repository.test.ts`, y `<provider>.adapter.test.ts` cuando el slice integra un tercero).
- **`src/app/` es solo cableado al framework.** El App Router enruta el filesystem: cada `route.ts` reexporta los handlers del slice, cada `page.tsx` LEE llamando a la función del service (`listMyLinks(actor)`) y los forms invocan `actions.ts` para mutar; ninguna lógica de negocio vive ahí.
- **Cuatro caminos en el borde: tres entrantes, uno saliente.** LECTURA → Server Component → función del service (sin `queries.ts`, sin `actions.ts`). MUTACIÓN → `actions.ts` (form/eventos) que cierra con `revalidatePath`/`revalidateTag`. API EXTERNA → `route.ts`, lo único que entra al contrato OpenAPI y a Schemathesis. EGRESO (saliente) → `<provider>.adapter.ts` sobre `core/http/client.ts`, la única vía hacia un tercero. Los tres primeros son request/response del navegador; el cuarto es la llamada saliente que el slice hace a un proveedor.
- **Unidad de Trabajo y optimistic locking son DIAL, no base.** Cuando una operación debe tocar varios repos atómicamente, se extrae `composition.ts` con `withTransaction(fn)` —abre `db.transaction(async (tx) => ...)` y pasa el handle `tx` a los repos participantes; los use cases quedan agnósticos de transacciones—. Cuando aparece escritura concurrente real sobre el mismo agregado (dos usuarios editando lo mismo con UX de conflicto), entra el optimistic locking: columna `version` en `table.ts`, `UPDATE ... WHERE id=? AND version=?` en el repositorio y `ConflictError` (code `conflict`) hacia arriba. Ninguno de los dos se scaffoldea por anticipación: el patrón completo vive en [Crear una feature](./08_how-to-crear-feature.md) para cuando el disparador llega.
- **`src/core/auth/` aloja la autenticación.** Better Auth con sesiones en Postgres (email/password + OAuth, Argon2id interno); el Actor se deriva SIEMPRE server-side de la sesión verificada, nunca de body/headers/params. La cookie de sesión es HttpOnly + Secure + SameSite=Lax, con expiración y rotación.
- **Código transversal en `src/core/`.** El pool y la conexión (`db/client.ts`), la configuración (`config.ts`), los errores base (`errors.ts`), la autorización (`authz.ts`), la traducción error → HTTP (`http/errors.ts`), el cliente HTTP de egreso (`http/client.ts`) y la observabilidad (`observability/`) viven bajo `src/core/`, nunca dentro de una feature. `core/` aloja el MECANISMO compartido del egreso (timeout, allowlist anti-SSRF); la integración concreta con cada proveedor vive en su `<provider>.adapter.ts` dentro del slice.
- **`src/shared/` con moderación.** Solo primitivas de dominio que de verdad comparten varias features; compartir de más vuelve a acoplar lo que la organización por feature separó.
- **`table.ts` ≠ `schemas.ts`.** `table.ts` es la tabla Drizzle (modelo de persistencia) y solo existe si la feature persiste; `schemas.ts` son los schemas Zod de I/O (el contrato público de la API). Son archivos distintos a propósito: separan el modelo de persistencia del contrato de borde.
- **`secrets/` está en `.gitignore`.** Contiene los `<env>.env` cuyos valores se materializan como Docker secrets en el despliegue (ver [Secretos](../operaciones/07_referencia-secretos.md)). `<env>` es el entorno (uno o varios); nunca se commitean.
- **La configuración de herramientas vive en la raíz, una por área.** `biome.json` (lint + format), `.dependency-cruiser.cjs` (pureza arquitectónica), `vitest.config.ts`, `drizzle.config.ts`, `tsconfig.json` y `next.config.ts`. Los scripts de `package.json` los orquestan; `pnpm run check` corre todos los gates (local = CI).
</content>
</invoke>
