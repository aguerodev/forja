---
id: arq.convenciones
titulo: Convenciones de código
tipo: referencia
tier: 2
audience: both
resumen: Referencia normativa de pureza del dominio, modelado, errores, tipado estricto, configuración y telemetría segura.
provides:
  - "pureza del dominio como allowlist"
  - "regla de modelado"
  - "columna version en entidad mutable (dial: entra con la escritura concurrente real, no por default)"
  - "mapeo Schema.parse como único cruce row->contrato"
  - "Unit of Work orquestada por el borde"
  - "bloqueo optimista"
  - "scopes/permisos como autorización"
  - "Actor"
  - "requirePermission"
  - "deny-by-default"
  - "jerarquía DomainError"
  - "toHttpResponse"
  - "assertNever"
  - "ErrorBody"
  - "tipado estricto"
  - "async nativo"
  - "getConfig + SECRETS_DIR"
  - "config sobre hardcode"
  - "logging y telemetría seguros"
  - "puerto HttpClient de core/http (borde de egreso; timeout requerido en la firma, no default de runtime)"
  - "política anti-SSRF del HttpClient (pinning de IP, redirects, rangos privados)"
  - "códigos upstream semánticos (upstream_unavailable / upstream_timeout / rate_limited / feature_disabled; el número HTTP vive solo en toHttpResponse)"
  - "efectos externos después del commit (nada de terceros dentro de withTransaction)"
  - "contrato de lectura del service list({filters,page,pageSize,sort}) -> {rows, total?}"
  - "searchParamsSchema validado en la page antes del service (sort/dir sobre allowlist de columnas; pageSize con .max() acotado)"
  - "concerns transversales con I/O como puerto (feature flags/audit/i18n/cache de lectura; default seguro; FeatureDisabledError)"
reads-before: [arq.hexagonal, arq.estructura-repo]
related: [ops.secretos]
---

# Referencia de las convenciones de código

Reglas de código, una por sección, con su fragmento normativo: **el único patrón correcto**. Donde la impone una herramienta, se indica. El porqué de fondo está en [Los principios del proyecto](../fundamentos/01_explicacion-principios.md) y [La arquitectura por dentro](./01_explicacion-arquitectura-hexagonal.md).

## 1. Pureza del dominio (la innegociable)

`domain.ts` y `ports.ts` no importan Next, Drizzle, `pg` ni Zod. Si necesitas el exterior, defines un puerto (una `interface` de TypeScript) y un adaptador lo implementa.

La regla es **allowlist, no denylist**: no enumeramos lo prohibido —esa lista nunca termina y deja fugas silenciosas (un paquete nuevo, un import transitivo)—; declaramos qué `domain.ts` y `ports.ts` **pueden** importar, y todo lo demás cae por defecto. Lo permitido:

- `./domain` y `./ports` (la propia capa de dominio del slice).
- `@/core/errors` (la jerarquía `DomainError`).
- `@/shared/*`, siempre que `shared` sea a su vez puro (misma regla, espejada con un contrato `shared-stays-pure`).
- La stdlib pura del lenguaje, sin I/O (nada de `node:fs`, `node:net`, etc.).

Cualquier otra cosa —Next, Drizzle, `pg`, Zod, un SDK, otro slice— queda fuera por no estar en la lista. Las fuentes no deterministas (reloj, aleatoriedad, identificadores generados) también: son I/O disfrazado y entran por un puerto, no se llaman directo desde `domain.ts`/`service.ts`.

→ Verificado por **dependency-cruiser** (contrato `domain-stays-pure`), expresado como allowlist (`forbidden` con `to.pathNot` de lo permitido, de modo que todo lo no listado cae): si un `domain.ts` importa Drizzle —o cualquier cosa fuera de la lista—, el build cae.

## 2. Regla de modelado

Hasta tres representaciones; usa el **mínimo**:

- **Schema (Zod): SIEMPRE.** Contrato de la API (`schemas.ts`).
- **Tabla ORM (Drizzle): SIEMPRE que se persista** (`table.ts`).
- **Entidad de dominio pura: SOLO si tiene reglas o invariantes que proteger** (`domain.ts`).

Heurística: *“¿esto tiene reglas, o solo guarda datos?”* Reglas → entidad pura, separada de la tabla. CRUD sin comportamiento → **no crees la tercera clase**; tabla + schema bastan. El triple modelado donde no aporta es la mayor fuente de esfuerzo y de bugs de sincronización entre representaciones.

## 3. Tablas ORM

Tabla Drizzle tipada con `pgTable`; el tipo se infiere del propio esquema sin anotaciones adicionales:

```ts
// src/features/counters/table.ts
import { integer, pgTable, text } from "drizzle-orm/pg-core";

export const counters = pgTable("counters", {
  id: text("id").primaryKey(),
  value: integer("value").notNull(),
});
```

`drizzle-kit` lee estas tablas (`schema: "./src/features/**/table.ts"`) para generar las migraciones versionadas. La tabla es el modelo de **persistencia**, separado a propósito del dominio.

La columna `version` (entero, soporte físico del **bloqueo optimista**) es una **escalación del dial**, no un campo de toda tabla: se agrega cuando aparece escritura concurrente real sobre el mismo agregado. Cuando entra, el caso de uso compara la versión al guardar y el `repository.ts` ejecuta `UPDATE ... WHERE id = ? AND version = ?` incrementándola (§5, DIAL). Las tablas de solo lectura o append-only nunca la necesitan.

## 4. Schemas y mapeo entidad → schema

Nunca expongas un row de Drizzle ni la entidad de dominio cruda en una respuesta: acoplar el esquema de BD al contrato público lo filtra. Cada Route Handler (o Server Action) serializa su salida con el schema Zod de vista, nunca con la fila ni la entidad directa. El mapeo entidad → schema va siempre vía `Schema.parse(...)`:

```ts
// src/features/counters/schemas.ts
import { z } from "zod";
import { extendZodWithOpenApi } from "@asteasolutions/zod-to-openapi";

extendZodWithOpenApi(z);

export const CounterView = z
  .object({ id: z.string(), value: z.number().int().nonnegative() })
  .openapi("CounterView");
export type CounterView = z.infer<typeof CounterView>;

// en route.ts:  return NextResponse.json(CounterView.parse(counter));
```

El schema **ES** el contrato: registrado con `.openapi()`, alimenta el OpenAPI 3.1 generado por `zod-to-openapi` que consume Schemathesis. `CounterView.parse(counter)` proyecta solo los campos públicos: aunque la entidad gane atributos internos, la respuesta no los filtra.

## 5. Puertos, adaptadores y punto de composición

Los puertos son `interface` de TypeScript (tipado estructural nativo del lenguaje), definidos en `ports.ts`. El adaptador los implementa en `repository.ts`. El cableado —qué implementación concreta entra en cada caso de uso— vive en el **punto de composición** del slice, `service.ts`:

```ts
// src/features/counters/ports.ts
// Capa de DOMINIO (PURA): el puerto que la feature necesita del exterior.
// Solo referencia tipos del dominio. No importa Drizzle, pg, Next ni Zod.
import type { Counter, CounterId } from "./domain";

export interface CounterRepository {
  findById(id: CounterId): Promise<Counter | null>;
  save(counter: Counter): Promise<void>;
}
```

```ts
// src/features/counters/use-cases.ts
// PURO: el caso de uso recibe el puerto y las deps no deterministas POR ARGUMENTO.
import { requirePermission, type Actor } from "@/core/authz";
import type { CounterRepository } from "./ports";

export async function incrementCounterUseCase(
  actor: Actor,
  id: string,
  repo: CounterRepository,
): Promise<Counter> {
  requirePermission(actor, "counters:increment"); // deny-by-default antes de mutar
  // ... regla de dominio + repo.save(...)
}
```

```ts
// src/features/counters/service.ts
// Punto de composición y fachada (server-only): pre-cablea el adaptador
// concreto en los use cases. Lo ÚNICO que route.ts/actions.ts importan.
import "server-only";
import type { Actor } from "@/core/authz";
import { createCounterRepository } from "./repository";
import { incrementCounterUseCase } from "./use-cases";

const _repo = createCounterRepository(); // singleton por proceso

export function incrementCounter(actor: Actor, id: string) {
  return incrementCounterUseCase(actor, id, _repo);
}
```

En tests, el fake se inyecta llamando al use case directo: `incrementCounterUseCase(actor, id, fakeRepo)`. Sin overrides mágicos ni cableado a mano en cada handler; el borde importa la función ya cableada de `service.ts`. Un `composition.ts` con factories por request es la **escalación del dial** (ver Unit of Work, abajo), no el punto de partida.

### Unit of Work: la transacción la orquesta el borde (DIAL)

> **Escalación, no default.** El slice base no tiene `composition.ts` ni `withTransaction`: su punto de composición es `service.ts` con el repo pre-cableado ([Arquitectura por dentro](./01_explicacion-arquitectura-hexagonal.md#qué-hace-cada-archivo)). Lo que sigue se activa cuando una operación debe tocar **varios repos como una sola unidad atómica** — ese es el disparador.

Cuando un caso de uso toca varios repositorios que deben confirmar o abortar como una sola unidad, la transacción es responsabilidad del **composition root**, no del dominio. El servicio recibe los repos ya cableados sobre el mismo handle transaccional y se mantiene **agnóstico de transacciones**: no sabe si corre dentro de una o no.

`withTransaction(fn)` vive en el composition root del slice (`composition.ts`), abre `db.transaction(...)` y construye el service con los repos atados al MISMO handle `tx`. Si `fn` lanza, Drizzle revierte; si retorna, confirma. El dominio y el servicio nunca importan `db.transaction` ni hablan de commits: el borde abre la unidad de trabajo y les pasa los repos ya participando en ella. Esto mantiene `service.ts` testeable con un fake síncrono y deja la orquestación transaccional en el único lugar que conoce las piezas concretas. La forma ejecutable canónica —única en la doctrina— vive en la sección "Una mutación de punta a punta" de [Crear una feature](./08_how-to-crear-feature.md).

**Regla normativa: ningún efecto de tercero dentro de `withTransaction`.** La frontera de consistencia transaccional **termina en Postgres**. Un email enviado, un objeto subido a un blob store o un cobro a un proveedor de pagos **no se revierten** si la transacción aborta después (conflicto optimista, fallo de otro repo): quedaría un correo de una operación que nunca se confirmó, el clásico *dual-write*. Además, una llamada de red lenta dentro de `db.transaction(...)` mantiene la conexión y los locks de fila todo ese tiempo, y un proveedor degradado satura el pool y tumba operaciones que ni tocan al tercero.

Por eso los efectos externos van **después del commit**: `withTransaction` retorna OK y recién entonces el borde dispara el envío. El reintento seguro es responsabilidad de la **operación del adaptador del proveedor** —que envía su propia clave de idempotencia (p. ej. el header `Idempotency-Key`), no del transporte genérico—; el efecto externo **debe ser idempotente**.

El post-commit tiene un modo de falla nombrado: **at-most-once** (el commit confirmó pero un crash entre el commit y el efecto pierde el envío). Cuando esa pérdida es inaceptable, el dial escala al patrón **outbox**: escribir una fila de intención **dentro de la misma transacción** y procesarla con un worker (garantía *at-least-once* sin *dual-write*), documentado como escalación, no como default. Simétricamente, cuando el borde es un **inbox** —un handler que recibe un webhook entrante—, la inserción de deduplicación (`processed_events`, `ON CONFLICT DO NOTHING`) va **dentro de la misma `withTransaction`** que el cambio de estado, para que dedupe y mutación commiteen juntos y de forma atómica.

El ejemplo ejecutable del egreso post-commit (commit primero, efecto después, clave de idempotencia atada a la entidad) vive en la sección "Un efecto externo" de [Crear una feature](./08_how-to-crear-feature.md).

### Bloqueo optimista: `version` + `ConflictError` (DIAL)

> **Escalación, no default.** Se adopta cuando aparece **escritura concurrente real** sobre el mismo agregado (dos actores editando lo mismo, con UX de conflicto que mostrar). Hasta ese síntoma, las entidades no llevan `version` — agregarla por anticipación es ceremonia que ninguna consulta paga.

Las entidades mutables se versionan (columna `version`, §3). El servicio guarda comparando la versión que leyó; si otra escritura concurrente ya la movió, el repository devuelve cero filas afectadas y traduce eso a un `ConflictError` (`code: "conflict"`, jerarquía `DomainError` de §7). Sin bloqueos pesimistas ni `SELECT ... FOR UPDATE` por defecto: la última escritura no gana en silencio, **falla explícito**.

La guarda se materializa en el repositorio con un `UPDATE ... WHERE id = ? AND version = ?` atómico que incrementa `version` en el mismo statement: o la fila sigue en la versión leída y avanza, o el conflicto sube al borde, donde `toHttpResponse` lo traduce a `409` (§7) y la Server Action lo convierte en estado de form (§7). El `version + 1` lo escribe el adaptador, no el dominio. El código canónico —tabla, repositorio, service y action de punta a punta— vive en la sección "Una mutación de punta a punta" de [Crear una feature](./08_how-to-crear-feature.md).

### El borde de egreso: el puerto `HttpClient`

Toda llamada saliente a un tercero (mailer, pasarela de pago, blob store, ERP) es **I/O**: cruza por un puerto, nunca con `fetch` crudo a una URL arbitraria desde un adaptador. El cuarto camino del borde es el **egreso**; su puerto canónico vive en `core/` y su política es **obligatoria**:

- **Timeout requerido en la firma.** `fetch` en Node no tiene timeout por defecto: una llamada colgada retiene el request y, bajo carga, agota el event loop o el pool. El `timeoutMs` es un parámetro **requerido** del puerto, no un default de runtime: si un adaptador lo omite, `tsc` rompe el build. El valor concreto sale de `config`.
- **Hook anti-SSRF, enforcement disparado por el origen de la URL.** El cliente **expone** un hook de validación de host/IP. Su enforcement es **obligatorio solo cuando la URL destino deriva de datos de usuario o de un tercero** (ese es el disparador); para destinos **constantes de `config`** la superficie SSRF es cero y el hook no agrega valor. Cuando aplica, hay que hacerlo **correcto**: resolver DNS, **validar y PINEAR la IP** en la conexión —sin re-resolver al abrir el socket, para no abrir DNS rebinding/TOCTOU—, **re-validar cada redirect** (o desactivar redirects), y rechazar los **rangos completos**: `127.0.0.0/8`, `::1`, `169.254.0.0/16` (incluye el endpoint de metadata de nube), `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`, `fe80::/10` y las IPv4-mapeadas.

La idempotencia del reintento **no vive en este puerto**: es responsabilidad de la **operación del adaptador del proveedor** (su propio header `Idempotency-Key`, §5), no del transporte genérico. El `HttpClient` transporta bytes; no conoce la semántica de negocio.

```ts
// src/core/http/client.ts
// Puerto de egreso: contrato que todo adaptador de tercero consume.
// Es interface pura; la implementación concreta (fetch + guardas) se cablea
// en composition.ts, igual que cualquier otro puerto.
export interface HttpRequest {
  readonly method: "GET" | "POST" | "PUT" | "DELETE";
  readonly url: string;
  readonly body?: unknown;
  readonly headers?: Readonly<Record<string, string>>;
  // REQUERIDO: sin default de runtime. Si el adaptador lo omite, tsc rompe.
  readonly timeoutMs: number;
  // Activa el enforcement del hook anti-SSRF. Se pone en true SOLO cuando la
  // URL deriva de datos de usuario/tercero; para destinos constantes de config
  // la superficie SSRF es cero y queda en false (default del adaptador).
  readonly validateDestination?: boolean;
}

export interface HttpClient {
  // La implementación aplica el timeout requerido y, si validateDestination,
  // el hook anti-SSRF: resuelve DNS, PINEA la IP validada en la conexión (no
  // re-resuelve al abrir el socket → sin DNS rebinding/TOCTOU), re-valida cada
  // redirect y rechaza los rangos privados/link-local/IPv4-mapeadas completos.
  // Lanza un error de egreso que el adaptador TRADUCE a DomainError.
  send(req: HttpRequest): Promise<HttpResponse>;
}
```

→ El seam de egreso es un **gate**, no prosa: un contrato de **dependency-cruiser** `egress-through-httpclient` **prohíbe importar primitivas de red crudas** (`undici`, `axios`, `node:http`/`node:https`) fuera de `src/core/http`. Quien quiera salir a la red lo hace por el puerto o el build cae. **Honestidad del gate:** el `fetch` **global** no tiene import, así que dependency-cruiser no puede verlo — esa mitad se sostiene por convención y revisión; una regla de lint dedicada es entrada del dial (disparador: la primera violación de `fetch` crudo en código de servidor que se escape a un PR). Un contrato de capas más, junto a `domain-stays-pure` (§1) y el resto del catálogo de dependency-cruiser de [la arquitectura por dentro](./01_explicacion-arquitectura-hexagonal.md).

Cada integración de tercero vive en su **hogar canónico del slice**: `src/features/<feature>/<provider>.adapter.ts`, que implementa un puerto declarado en `ports.ts` y consume `HttpClient`. El SDK, la firma y los tipos del proveedor **nunca salen del adaptador**; el dominio ve solo el puerto. Y, como cualquier adaptador (§7), **traduce el error del proveedor a un `DomainError`**: un timeout, un `5xx` o un `429` del upstream se vuelven los códigos de fallo de dependencia de §7, nunca escapan crudos a `service.ts`.

```ts
// src/features/billing/payments.adapter.ts (extracto): traduce el fallo de egreso.
import { UpstreamTimeoutError, UpstreamUnavailableError } from "@/core/errors";
import { getConfig } from "@/core/config";

async charge(input: ChargeInput): Promise<Receipt> {
  try {
    const res = await this.http.send({
      method: "POST",
      url: this.endpoint, // destino constante de config: no necesita validación SSRF
      body: toProviderPayload(input),
      timeoutMs: getConfig().<clave-timeout-pagos>, // requerido por la firma
      headers: { "Idempotency-Key": input.chargeId }, // idempotencia de la OPERACIÓN
    });
    return toReceipt(res.body); // la forma del proveedor NO sale de aquí
  } catch (error) {
    // El error de egreso se traduce a DomainError; el dominio nunca ve el SDK.
    if (error instanceof EgressTimeoutError) {
      throw new UpstreamTimeoutError("payment provider timed out", { cause: error });
    }
    throw new UpstreamUnavailableError("payment provider unavailable", { cause: error });
  }
}
```

### El service expone lecturas ricas: la firma `list`

El `service.ts` **puede** —y debe— exponer métodos de lectura ricos; no existe un `queries.ts` intermedio. El camino de lectura es Server Component → la función de lectura del service (`listCounters(actor, query)`), sin transacción (las lecturas no la necesitan; solo las mutaciones atómicas usan `withTransaction`, §5). Para que una tabla paginada renderice su control de paginación, la firma canónica de la lectura es:

```ts
// src/features/counters/service.ts (extracto): contrato de lectura canónico.
export interface ListQuery {
  readonly filters?: CounterFilters;   // forma tipada del slice, no `any`
  readonly page?: number;              // offset por defecto
  readonly pageSize?: number;
  readonly sort?: ReadonlyArray<SortField>;
}

export interface ListResult {
  readonly rows: ReadonlyArray<CounterView>;
  // OPCIONAL por contrato: offset lo devuelve cuando la UI muestra el total de
  // páginas; cursor lo OMITE (un COUNT exacto por página sería caro e inútil).
  readonly total?: number;
}

// list({ filters, page, pageSize, sort }) -> { rows, total? }
async list(query: ListQuery): Promise<ListResult> { /* ... */ }
```

Los `searchParams` del request se validan con un schema Zod **en la page, antes** de invocar el service: la entrada no validada nunca llega a la query. Ese `searchParamsSchema` es el contrato de I/O del borde y vive en su **hogar canónico**, `schemas.ts` (§4); la page lo **invoca**, no lo define. Dos reglas duras del schema: `sort` y su dirección van sobre una **allowlist** de columnas ordenables (`z.enum`), nunca un string libre que termine concatenado a un `ORDER BY` (vector de inyección); y `pageSize` lleva un `.max()` explícito con default acotado (un `pageSize` sin tope deja al cliente pedir la tabla entera en una request). El schema ejecutable y la page que lo invoca viven en la sección "Una lectura paginada" de [Crear una feature](./08_how-to-crear-feature.md).

La paginación es **offset por defecto**; el cursor es un dial cuyo disparador es de **performance, no estético**: tablas grandes donde el `COUNT` exacto se vuelve caro o el offset profundo degrada. Con offset y `total`, ojo: **sin una transacción que envuelva ambas queries, `rows` y `total` son snapshots distintos** (una escritura concurrente entre las dos deja un total que no cuadra con las filas): lectura no atómica, aceptable para paginación pero no para invariantes. Las filas se proyectan con `Schema.parse` (§4) igual que cualquier salida: nunca la fila de Drizzle cruda.

### Los concerns transversales no son un patrón nuevo

Lo transversal con I/O —feature flags, audit log, i18n, caché de lectura— **sigue la regla de puerto ya existente** (§5), no es un patrón aparte: se declara como `interface` en `core`/`shared`, se evalúa en `service.ts` —que sí puede importar `core`— y pasa el resultado como dato plano a la función pura; **jamás se debilita el allowlist de pureza** (§1). Su modo de falla es el de cualquier adaptador: ante fallo de evaluación cae a un **default seguro** (típicamente *off* para un kill-switch) y, cuando un flag apaga una capacidad, el service levanta `FeatureDisabledError` (§7), no un fallo genérico.

## 6. Autorización

Mecanismo único: **permisos (scopes)**. Cada caso de uso que los requiera llama a una guarda explícita en `service.ts`, **antes** de cualquier cambio de estado, con política **deny-by-default**:

```ts
// src/core/authz.ts
import { PermissionDeniedError } from "./errors";

export interface Actor {
  // Identidad verificada server-side, humana o de máquina, sin distinción de
  // tipo: NADA ramifica sobre el origen. La autorización es por permisos
  // (deny-by-default), no por un discriminante. Sin tenantId ni orgId hasta
  // que multi-tenancy sea un objetivo real.
  readonly id: string;
  readonly permissions: ReadonlySet<string>;
}

export function requirePermission(actor: Actor | null, permission: string): void {
  // null = no autenticado; permiso ausente = denegado (deny-by-default).
  if (!actor) throw new UnauthenticatedError();
  if (!actor.permissions.has(permission)) {
    throw new UnauthenticatedError({ required: permission, reason: "permission_denied" });
  }
}
```

**Hogar de la guarda — UNA sola regla:** `requirePermission` se aplica en **`use-cases.ts`**, antes de cualquier cambio de estado; `service.ts` solo cablea el caso de uso con el adaptador real. En la variante del dial (service como factory con métodos), la guarda vive en el método del service — es la misma regla en el escalón siguiente, nunca en dos lugares a la vez.

### El Actor se deriva server-side de la sesión verificada

El `Actor` se construye **siempre server-side a partir de la sesión verificada**, nunca de datos que el cliente controla. El `id` y los `permissions` salen del **store de sesión/usuario**, jamás del `body`, los `headers` ni los `params`: aceptar un actor desde el request es confiar en el cliente sobre quién es y qué puede hacer, el agujero de autorización clásico.

La autenticación la provee **Better Auth** (TS-first, sesiones en Postgres, email/password + OAuth, hashing Argon2id interno; el módulo de auth vive en el core). La cookie de sesión es `HttpOnly`, `Secure` y `SameSite=Lax`, con expiración y rotación de sesión; los detalles normativos están en [Autenticación y sesión](./05_referencia-auth-y-sesion.md). El borde resuelve la sesión a partir de esa cookie y recién entonces arma el `Actor`:

```ts
// src/core/auth/actor.ts
// El Actor NACE de la sesión verificada. Nunca se acepta desde el request.
import { headers } from "next/headers";
import { auth } from "@/core/auth"; // instancia de Better Auth
import { loadPermissions } from "@/core/auth/permissions";
import type { Actor } from "@/core/authz";

export async function getActor(): Promise<Actor | null> {
  // Better Auth valida la cookie HttpOnly y devuelve la sesión, o null.
  const session = await auth.api.getSession({ headers: await headers() });
  if (!session) return null;

  // Permisos desde el store de sesión/usuario, NO desde el request.
  const permissions = await loadPermissions(session.user.id);
  return { id: session.user.id, permissions };
}

// En el borde (route.ts / actions.ts), antes de tocar el service:
//   const actor = await getActor();
//   if (!actor) return unauthorized();            // sin sesión, deny-by-default
//   await incrementCounter(actor, input); // la función del service, ya cableada
```

El borde resuelve el `Actor` y lo pasa al servicio; el servicio aplica `requirePermission` **antes de cualquier cambio de estado**, **deny-by-default**: ausencia de sesión o de permiso explícito = denegado. La guarda vive en `service.ts` (no solo en el borde) para que ningún punto de entrada —`route.ts`, `actions.ts` o un test de integración— pueda saltársela. Cada permiso debe tener su [test negativo](./04_explicacion-testing.md#tests-negativos-de-autorización).

### El Actor de máquina: identidad no-humana por el mismo seam (DIAL)

> **Escalación, no default.** Este detalle se implementa recién cuando el proyecto expone su **primera superficie máquina-a-máquina real** (una API key para un partner, un webhook entrante).

Lo que el slice base garantiza es el **seam**: `Actor` sin discriminante de origen y `requirePermission` ciego al derivador. Una API key o un webhook firmado producen el **MISMO tipo `Actor`** que una sesión de navegador, de modo que `service.ts` y el deny-by-default no cambian; un actor de máquina es solo un `Actor` con su set de permisos. Si algún consumidor necesita ramificar por origen (p. ej. saltar la protección CSRF de sesión para un caller de máquina), esa rama vive **en el derivador del borde**, no en un discriminante propagado a cada `service.ts`. La implementación de referencia de los derivadores (`getActorFromSession`, `getActorFromApiKey`, `getActorFromWebhook`) —key-id público + secreto, hash SHA-256 comparado en tiempo constante, CSPRNG ≥256 bits mostrado una vez, HMAC con anti-replay— es normativa en [Autenticación y sesión](./05_referencia-auth-y-sesion.md).

## 7. Manejo de errores

El dominio levanta errores explícitos (jerarquía a partir de `DomainError`). `domain.ts` y `service.ts` no conocen códigos HTTP. La traducción error → respuesta HTTP ocurre **solo** en `src/core/http/errors.ts` (`toHttpResponse`): único punto de conversión en toda la app.

```ts
// src/core/errors.ts
// El conjunto de códigos es una UNIÓN CERRADA: es lo que da exhaustividad
// al compilador. La jerarquía de clases sola no la da (ver más abajo).
// La lista de literales vive UNA sola vez, como array `as const`: de ahí se
// deriva el tipo y de ahí consume el z.enum del contrato (ErrorBody).
export const DOMAIN_ERROR_CODES = [
  // Dominio propio.
  "not_found",
  "conflict",
  "permission_denied",
  // Fallo de dependencia upstream: TODA integración externa los necesita el
  // día uno. El adaptador de egreso (§5) traduce el fallo del proveedor a uno
  // de estos códigos SEMÁNTICOS; el dominio nunca ve el SDK. Ningún código
  // hornea el número de status HTTP: esa traducción vive SOLO en route.ts
  // (toHttpResponse), la única capa que habla HTTP. El nombre describe el
  // SIGNIFICADO, no el transporte.
  "upstream_unavailable", // el upstream no respondió o respondió algo inválido
  "upstream_timeout",     // el upstream no respondió a tiempo
  "rate_limited",         // se agotó la cuota (propia o del upstream)
  // Kill-switch: la capacidad está apagada por un flag (puerto transversal, §5).
  "feature_disabled",     // capacidad apagada para este caller
] as const;

export type DomainErrorCode = (typeof DOMAIN_ERROR_CODES)[number];

export abstract class DomainError extends Error {
  abstract readonly code: DomainErrorCode;
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = new.target.name;
  }
}

export class NotFoundError extends DomainError {
  readonly code = "not_found";
}
export class ConflictError extends DomainError {
  readonly code = "conflict";
}
export class PermissionDeniedError extends DomainError {
  readonly code = "permission_denied";
  constructor(permission: string) {
    super(`missing required permission: ${permission}`);
  }
}

// Errores de dependencia upstream: el adaptador de egreso (§5) los levanta al
// traducir el fallo del proveedor. Llevan datos estructurados, no strings ya
// armados, para que el cuerpo de error transporte `params` (i18n, Retry-After).
export class UpstreamUnavailableError extends DomainError {
  readonly code = "upstream_unavailable";
}
export class UpstreamTimeoutError extends DomainError {
  readonly code = "upstream_timeout";
}
export class RateLimitedError extends DomainError {
  readonly code = "rate_limited";
  // El upstream (o la API propia) indica cuándo reintentar; viaja en `params`.
  constructor(message: string, readonly retryAfterSeconds?: number) {
    super(message);
  }
}
export class FeatureDisabledError extends DomainError {
  readonly code = "feature_disabled";
}

// Los errores de una feature extienden esta jerarquía en su domain.ts y
// REUTILIZAN el código de su base (no inventan uno suelto), de modo que el
// switch exhaustivo de toHttpResponse los traduce sin tocar:
//   export class CounterPersistenceError extends ConflictError {} // hereda "conflict"
// Si una feature necesita un código propio, lo agrega a DomainErrorCode:
// el switch deja de compilar hasta que se maneja su caso (ese es el punto).
```

La traducción error → HTTP en `toHttpResponse` usa un **switch exhaustivo sobre `DomainErrorCode`**, no una cadena de `instanceof`. La jerarquía de clases por sí sola NO le da exhaustividad al compilador: si una feature agrega un código y olvida su caso, una cadena de `instanceof` cae al `else` en runtime sin que `tsc` avise. El `never` cierra ese hueco en compilación. El **cuerpo tipado `{ code, params?, message? }`** que devuelve es parte del contrato: se registra en el OpenAPI como la forma estándar de las respuestas `4xx`/`5xx` (ver más abajo).

```ts
// src/core/http/errors.ts: único punto de traducción error → HTTP.
import type { DomainError } from "@/core/errors";

function assertNever(value: never): never {
  throw new Error(`unhandled domain error code: ${String(value)}`);
}

// Cuerpo de error tipado: ES parte del contrato OpenAPI (respuestas 4xx/5xx).
// La forma es `{ code, params?, message? }`: `code` es la clave estable; `params`
// alimenta la interpolación i18n y los metadatos (p. ej. retryAfter); `message`
// es fallback/debug saneado (§12), no el contrato.
export interface ErrorBody {
  code: DomainErrorCode;
  params?: Record<string, string | number>;
  message?: string;
}

export function toHttpResponse(error: DomainError): Response {
  const body: ErrorBody = { code: error.code, message: error.message };
  switch (error.code) {
    case "not_found":
      return Response.json(body, { status: 404 });
    case "conflict":
      return Response.json(body, { status: 409 });
    case "permission_denied":
      return Response.json(body, { status: 403 });
    case "upstream_unavailable":
      // El upstream no respondió o respondió algo inválido. El NÚMERO vive
      // solo aquí: el código de dominio es semántico, esto es transporte.
      return Response.json(body, { status: 502 });
    case "feature_disabled":
      // Kill-switch: el recurso existe pero no está sirviendo ahora → 503.
      // (Puede mapear a 404 si la semántica es "no existe para este caller";
      // se decide por recurso.)
      return Response.json(body, { status: 503 });
    case "upstream_timeout":
      return Response.json(body, { status: 504 });
    case "rate_limited":
      // El 429/503 propaga Retry-After desde `params`, parte del contrato.
      return Response.json(
        { ...body, params: { ...body.params } },
        { status: 429, headers: retryAfterHeader(error) },
      );
    default:
      // Si se agrega un código a DomainErrorCode y falta su caso aquí,
      // `error.code` deja de ser `never` y el build cae. El guardarraíl
      // es el tipo, no la disciplina de recordar el caso.
      return assertNever(error.code);
  }
}
```

El cuerpo `{ code, params?, message? }` **es parte del contrato OpenAPI**, no un detalle de implementación: se modela como un schema Zod (§4) registrado con `.openapi("ErrorBody")` y se declara como la respuesta estándar de los estados `4xx`/`5xx` de cada operación. Así el documento OpenAPI 3.1 que sirve el `OpenAPIRegistry` central (`src/core/http/openapi.ts`) describe éxito y error, y Schemathesis fuzzea contra esa forma —incluidos los caminos de fallo de dependencia `502`/`503`/`504`/`429` y el kill-switch—. `code` es la unión cerrada `DomainErrorCode`; `params` lleva los datos estructurados para que el cliente interpole su propio texto (i18n) o lea metadatos como `retryAfter`; `message` es un fallback legible y **saneado** (nunca filtra internals ni datos sensibles, §12). El dominio levanta el error con **datos estructurados**, no con un string ya armado en un idioma: la separación `code` + `params` mantiene la traducción en el borde (`messageForCode(code, params, locale)`), nunca en `domain.ts`.

```ts
// src/core/http/error-schema.ts: el cuerpo de error como contrato OpenAPI.
import { z } from "zod";
import { extendZodWithOpenApi } from "@asteasolutions/zod-to-openapi";
import { DOMAIN_ERROR_CODES } from "@/core/errors";

extendZodWithOpenApi(z);

export const ErrorBody = z
  .object({
    // La unión cerrada se REUTILIZA desde core/errors: una sola lista de literales.
    code: z.enum(DOMAIN_ERROR_CODES),
    // Datos para interpolar en el cliente y metadatos (p. ej. retryAfter).
    params: z.record(z.string(), z.union([z.string(), z.number()])).optional(),
    // Fallback/debug saneado; el contrato estable es `code` + `params`.
    message: z.string().optional(),
  })
  .openapi("ErrorBody");
```

El adaptador **nunca deja escapar la excepción del proveedor**: la traduce a un error del dominio. El servicio y el dominio no importan la librería externa; ven solo el error del puerto.

```ts
// src/features/counters/repository.ts (adaptador): traduce pg.DatabaseError → error del dominio
try {
  await this.db
    .insert(counters)
    .values({ id: counter.id, value: counter.value })
    .onConflictDoUpdate({ target: counters.id, set: { value: counter.value } });
} catch (error) {
  if (error instanceof DatabaseError) {
    throw new CounterPersistenceError(
      `failed to persist counter ${counter.id}`,
      { cause: error },
    );
  }
  throw error;
}
```

Donde una operación deba mantener una **garantía** pese al fallo (p. ej. responder idéntico exista o no el recurso, para no filtrar su existencia), el servicio **captura** la excepción del dominio, la loguea server-side y devuelve la respuesta genérica. El porqué está en [una garantía no puede romperse por un fallo de adaptador](./04_explicacion-testing.md#una-garantía-no-puede-romperse-por-un-fallo-de-adaptador).

### Dos caminos de traducción: HTTP y estado de form

El mismo `DomainError` que levanta el servicio se traduce de **dos** maneras según el punto de entrada, y en ninguna se filtra crudo a la UI:

- **`route.ts` (API externa) → HTTP.** El Route Handler captura el `DomainError` y lo pasa por `toHttpResponse`: estado `4xx`/`5xx` + cuerpo `{ code, params?, message? }`. Ese es el camino del contrato OpenAPI que fuzzea Schemathesis.
- **`actions.ts` (mutación interna desde un form) → estado de form.** La Server Action **no** lanza hacia el cliente ni devuelve HTTP: devuelve un **estado serializable** que `useActionState` consume en el componente. Un `DomainError` se traduce a ese estado —mensaje por campo o mensaje general—, nunca se propaga la excepción cruda al cliente.

Una Server Action termina **siempre** con `revalidatePath`/`revalidateTag` del recurso afectado en el camino de éxito, y devuelve el estado del form en ambos caminos. El tipo del estado es explícito y serializable (sin instancias de `Error`, sin clases):

```ts
// src/features/counters/actions.ts
"use server";

import { revalidatePath } from "next/cache";
import { DomainError } from "@/core/errors";
import { getActor } from "@/core/auth/actor";
import { incrementCounter } from "./service";
import { IncrementInput } from "./schemas";

// Estado serializable que consume useActionState en el cliente.
export interface CounterFormState {
  status: "idle" | "success" | "error";
  // Mensaje general (no liga a un campo): permiso, conflicto, fallo genérico.
  formError?: string;
  // Mensajes por campo: validación de entrada o reglas de dominio.
  fieldErrors?: Record<string, string>;
}

// Sufijo Action: la action NUNCA repite el nombre de la función del service
// que importa (colisionarían en el mismo módulo y la llamada interna se
// volvería recursiva).
export async function incrementCounterAction(
  _prev: CounterFormState,
  formData: FormData,
): Promise<CounterFormState> {
  const actor = await getActor();
  if (!actor) return { status: "error", formError: "No autorizado" };

  // Validación de entrada → errores por campo (no se lanza al cliente).
  const parsed = IncrementInput.safeParse(Object.fromEntries(formData));
  if (!parsed.success) {
    return { status: "error", fieldErrors: flattenFieldErrors(parsed.error) };
  }

  try {
    await incrementCounter(actor, parsed.data);
    revalidatePath("/counters"); // revalida el recurso afectado
    return { status: "success" };
  } catch (error) {
    // El DomainError se TRADUCE a estado de form; nunca se filtra crudo.
    if (error instanceof DomainError) {
      return { status: "error", formError: messageForCode(error.code) };
    }
    throw error; // lo inesperado sube al boundary de error, no a la UI
  }
}
```

`messageForCode` mapea el `DomainErrorCode` (unión cerrada) a un texto de UI: un `conflict` se vuelve "el contador cambió, recargá y reintentá"; un `permission_denied`, "no tenés permiso". La UI recibe datos, nunca la excepción ni su `stack`. Las Server Actions son **RPC internas**: no entran al contrato OpenAPI (eso es `route.ts`); se cubren con tests de integración.

## 8. Tipado estricto

Todo se anota. `tsc --noEmit` con `strict: true` bloquea el merge: nada de `any` implícito. Un `@ts-expect-error` debe ser específico y justificado (apunta a un error concreto, con su razón); **Biome bloquea los ignores en blanco**: un supresor sin justificar es error de lint. La regla la impone la herramienta, no una convención escrita.

Las **aserciones de tipo (`as`) están prohibidas** salvo `as const`. `noExplicitAny` atrapa `as any`, pero NO `as SomeType` ni el doble `as unknown as T` —el atajo exacto con el que se "arregla" un error de tipos sin entender la forma del dato—, y una sola aserción en `repository.ts` o en el mapeo entidad → schema invalida en silencio toda la cadena de inferencia. El patrón correcto:

- **Validar la forma desconocida** (entrada, fila, payload externo) con `Schema.parse()`: convierte con prueba en runtime, no con una promesa al compilador.
- **Fijar una forma conocida** con `satisfies`: comprueba contra el tipo sin ensancharlo.
- **Estrechar un tipo** con un **type guard** (`function isX(v): v is X`), no con `as`.

Un `as` que sobreviva a esto es interop legítima con un tipo que el compilador no puede ver, y lleva su razón al lado, igual que un `@ts-expect-error`. Cero `as` sin justificación; no es la herramienta para hacer encajar datos cuya forma no se validó.

## 9. Async nativo (no es escalación del dial)

Los Route Handlers, Server Actions y el acceso a datos son asíncronos por naturaleza: en Node el event loop hace todo el I/O `async` de forma nativa. Drizzle es async y no añade complejidad por ello; los handlers exportan funciones `async` y el repositorio devuelve `Promise<...>`. **No existe un eje sync/async que gestionar**: todo el I/O es async de forma uniforme (ver la [referencia del stack](../fundamentos/03_referencia-stack-desarrollo.md#notas-de-las-decisiones)). Lo que **sí** sube en el dial son streaming/SSE/websockets como features deliberadas.

## 10. Configuración

Un único módulo `config` que sirve a los dos mundos: en **prod** lee los valores como **archivos** de `/run/secrets` (Docker secrets); en **local** lee variables de entorno o un `.env`. El contrato es: **el nombre del secret = el nombre del campo**.

```ts
// src/core/config.ts
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";

const SECRETS_DIR = "/run/secrets";

function readSource(field: string): string | undefined {
  const secretFile = join(SECRETS_DIR, field);
  if (existsSync(secretFile)) return readFileSync(secretFile, "utf8").trim();
  return process.env[field.toUpperCase()];
}

// El PATRÓN es lo normativo, no estos nombres: cada proyecto declara sus
// propios campos. Un campo por secret; el contrato es nombre-de-secret = campo.
const ConfigSchema = z.object({
  <clave-conexion-bd>: z.string().min(1),
  <clave-firma-sesion>: z.string().min(1),
  <clave-servicio-externo>: z.string().min(1),
  <clave-telemetria>: z.url().optional(),
});

export type Config = z.infer<typeof ConfigSchema>;

let cached: Config | undefined;

export function getConfig(): Config {
  if (cached) return cached;
  const raw = Object.fromEntries(
    Object.keys(ConfigSchema.shape).map((field) => [field, readSource(field)]),
  );
  // Falla rápido al arrancar si falta un secret o tiene mal formato.
  cached = ConfigSchema.parse(raw);
  return cached;
}
```

Secretos nunca en el repo; en local, un `.env` en `.gitignore`. El archivo en `/run/secrets` y la variable de entorno comparten el nombre del campo, sin prefijo: el contrato simple “secret = campo” gana. Cómo se materializan y rotan esos secrets está en [la referencia de secretos](../operaciones/07_referencia-secretos.md).

## 11. Config sobre hardcode

Los valores de **despliegue** —dominios, direcciones de correo, URLs base— van en `config`, **nunca** hardcodeados. Antipatrón concreto: un remitente de correo fijado en el adaptador a un dominio **no verificado** en el proveedor hace que todos los envíos sean rechazados. El patrón correcto: mover ese valor a config (con default sensato apuntando al dominio verificado) e inyectarlo en el adaptador.

```ts
const ConfigSchema = z.object({
  // ...
  // config, no literal en el adaptador:
  <clave-remitente-correo>: z.string().default("noreply@<dominio-verificado>"),
});
```

Señal de alarma: **cualquier string de dominio, URL o dirección literal dentro de un adaptador** es candidato a ser config. El adaptador recibe el valor inyectado; no lo conoce de antemano.

## 12. Logging y telemetría seguros (qué nunca se loguea)

La garantía de privacidad que el borde HTTP protege —p. ej. no revelar por el status code si un recurso existe (§7)— se rompe si ese dato termina en claro en los logs o en el reporte de errores. Por eso el qué **nunca** se loguea es normativo, no criterio del autor.

**Nunca se loguea en claro:** contraseñas y sus hashes, tokens, claves (cualquier secret de `config`), las cabeceras `Authorization` y `Cookie`, y PII directa (email, nombre, dirección). El usuario se identifica en los logs por su **id opaco**, nunca por su email. Donde un servicio captura un fallo para sostener una garantía (§7), loguea un id de correlación o un hash, **no la PII del interesado**.

**pino** se configura con `redact` —no es opcional— de modo que el censurado ocurra aunque alguien pase un objeto entero por descuido:

```ts
// src/core/logger.ts
import pino from "pino";

export const logger = pino({
  redact: {
    paths: [
      "password",
      "*.password",
      "*.token",
      "*.email",
      "req.headers.authorization",
      "req.headers.cookie",
    ],
    censor: "[REDACTED]",
  },
});
```

`redact` es la red de seguridad, no la regla. La regla es no pasar entidades de dominio ni filas de Drizzle crudas al logger: se loguean campos proyectados (id, `code`, `requestId`), nunca la entidad directa —el principio de §4 aplicado al canal de telemetría.

**Sentry** (`@sentry/nextjs`) por defecto adjunta IP, cabeceras, query string y cuerpo de request a cada excepción. Eso se apaga y, lo que quede, se escruba antes de que el evento salga del proceso:

```ts
// src/core/sentry.ts
import * as Sentry from "@sentry/nextjs";
import { getConfig } from "@/core/config";

Sentry.init({
  dsn: getConfig().<clave-telemetria>,
  sendDefaultPii: false, // sin IP, sin cookies, sin datos de usuario por defecto
  beforeSend(event) {
    // Escrubea PII antes de emitir el evento.
    event.user = undefined;
    if (event.request) {
      event.request.cookies = undefined;
      event.request.data = undefined;
      if (event.request.headers) {
        delete event.request.headers.authorization;
        delete event.request.headers.cookie;
      }
    }
    return event;
  },
});
```

→ Guardarraíl ejecutable: un test verifica que el logger censura los `paths` de `redact` y que `beforeSend` deja el evento sin PII. La convención vive en la herramienta y en su test, no en este párrafo.
