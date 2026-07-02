---
id: arq.crear-feature
titulo: Crear una feature
tipo: how-to
tier: 2
audience: both
resumen: Guía capstone de seis pasos para añadir una feature de negocio, con un ejemplo end-to-end de transacción y bloqueo optimista.
provides:
  - "receta de seis pasos para una feature nueva"
  - "generación local de migraciones"
  - "FormState / useActionState"
  - "ejemplo end-to-end de transacción + bloqueo optimista"
  - "ejemplo end-to-end de egreso post-commit (adaptador de egreso + efecto disparado tras withTransaction)"
  - "ejemplo end-to-end de lectura paginada (searchParamsSchema ejecutable + firma list del service)"
  - "webhook idempotente at-least-once (dedupe por inbox; evento veneno + dead-letter)"
reads-before: [arq.hexagonal, arq.estructura-repo, arq.convenciones, arq.testing]
related: [proc.sdd, arq.auth, arq.estilos-frontend, arq.gates-tooling]
---

# Cómo crear una feature

Receta canónica para añadir un contexto de negocio nuevo: siempre estos seis pasos, en este orden. Da por sentada la estructura de una feature (la [Referencia de la estructura del repositorio](./02_referencia-estructura-repo.md)) y las [Convenciones de código](./03_referencia-convenciones-codigo.md), a las que remite donde hace falta.

Una feature realiza un cambio especificado en `openspec/changes/<cambio>/`, que a su vez concreta requisitos de `docs_sdd/`. Es el último eslabón del handoff `docs_sdd/ → openspec/ → src/`; el mapa completo de esa cadena está en [SDD, flujo de especificación y Gentle AI](../proceso/03_explicacion-sdd.md).

## Pasos

1. **Crea el esqueleto copiando la forma de un slice existente.** La feature nace en su propia rama `feature/<nombre>` desde `develop` y vuelve por PR ([el modelo de ramas](../proceso/01_explicacion-trabajo-con-ia.md)). Mientras el generador de Plop no exista ([estado real del scaffold](./07_referencia-gates-tooling.md#scaffold-el-estado-real-y-el-objetivo)), la fuente de la forma es un slice vigente del repo: creá `src/features/<feature>/` con los archivos canónicos —`domain.ts`, `ports.ts`, `use-cases.ts`, `service.ts`, `schemas.ts`, `repository.ts`, `route.ts`, `actions.ts`, `public.ts`, y `table.ts` solo si persiste— y sus espejos en `tests/unit/features/<feature>/` y `tests/integration/features/<feature>/`. La responsabilidad de cada archivo vive en la [estructura del repositorio](./02_referencia-estructura-repo.md); esta receta los produce, no los reenumera.

2. **Escribe el test rojo primero.** En `tests/unit/features/<feature>/`, escribe la primera invariante o caso de uso, sin I/O, con un fake en memoria del puerto. Usa **fast-check** para invariantes del dominio en `domain.test.ts`; usa **Vitest** puro para casos de uso en `use-cases.test.ts` — el fake se pasa por argumento, sin mocks de framework. El test rojo define qué es "hecho".

3. **Modela lo mínimo.** Aplica la [regla de modelado](./03_referencia-convenciones-codigo.md): schema Zod en `schemas.ts` siempre; tabla Drizzle en `table.ts` si se persiste; entidad de dominio pura en `domain.ts` solo si hay comportamiento o invariantes que proteger.

4. **Implementa hasta verde.** Pon la regla en `domain.ts` y el caso de uso en `use-cases.ts` como función pura que recibe `Actor`, input validado, el puerto y las dependencias no deterministas (ids, reloj) **por argumento**, con su guarda de [autorización](./03_referencia-convenciones-codigo.md) (`requirePermission(actor, permission)`) antes de cualquier cambio de estado.

5. **Conecta el borde.** Escribe el adaptador en `repository.ts` (implementa el puerto con Drizzle; traduce `DatabaseError` de pg a un error del dominio; los use cases nunca ven la excepción del proveedor). Cablea en `service.ts` (punto de composición server-only): instancia el repo concreto y exporta funciones con el caso de uso ya cableado — `route.ts` y `actions.ts` importan SOLO de acá. (Si una operación necesita transacción multi-repo, ese es el disparador para extraer `composition.ts` + `withTransaction(fn)`: dial, ver el ejemplo más abajo.) El borde reparte cuatro caminos —tres entrantes y uno saliente:
   - **LECTURA** (entrante) → el Server Component (`src/app/<feature>/page.tsx`) lee llamando a la función del service: `await list<Feature>(actor, query)`. Los `searchParams` se validan con `searchParamsSchema` (Zod, en `schemas.ts`) **antes** de invocar al service. No hay `queries.ts` ni se lee vía `actions.ts`.
   - **MUTACIÓN** (entrante) → `actions.ts` (`"use server"`) para forms y eventos: valida con Zod, invoca el service, cierra con `revalidatePath`/`revalidateTag` del recurso, y devuelve un estado serializable para `useActionState` (un `DomainError` se traduce a estado de form/campo, nunca crudo).
   - **API EXTERNA** (entrante) → `route.ts` (Route Handlers): valida con Zod, invoca el service, delega la traducción error → respuesta HTTP a `core/http/errors.ts`, y registra la operación en el `OpenAPIRegistry` (es lo que entra al contrato y lo que Schemathesis fuzzea). Si recibe **webhooks** at-least-once, deduplica por `(source, event_id)` con la tabla `processed_events` y responde `200` a la entrega repetida (no `409`).
   - **EGRESO** (saliente) → `<provider>.adapter.ts`: toda llamada **a un tercero** (mailer, pasarela de pago, object storage, ERP) sale por un puerto declarado en `ports.ts` que cumple este adaptador sobre el `HttpClient` de `core/` (timeout obligatorio + allowlist anti-SSRF). El SDK y la firma del proveedor nunca salen de aquí; traduce `provider → DomainError`. El efecto externo se dispara **después** del commit, jamás dentro de `withTransaction`.

6. **Registra y migra.** Añade el binding fino en `src/app/api/<feature>/route.ts` (`export { GET, POST } from "@/features/<feature>/route"`) — Next.js usa el filesystem como registro; no hay un `main.ts` central. Genera la migración con `pnpm drizzle-kit generate` y aplícala con `pnpm drizzle-kit migrate`. Corre `pnpm run check` para que pasen todos los gates.

---

> **Los ejemplos que siguen son patrones del DIAL, no del slice base.** Documentan las escalaciones ya resueltas —Unidad de Trabajo + optimistic locking, egreso post-commit, webhook idempotente— para ejecutarlas bien **cuando su disparador llegue** (transacción multi-repo, primer tercero, primer webhook). Un slice sin esos síntomas no scaffoldea nada de esto.

## Una mutación de punta a punta: transacción + optimistic locking

La Unidad de Trabajo vive en el composition root: `withTransaction(fn)` abre `db.transaction(...)` y pasa el handle `tx` a los repos participantes. El service queda agnóstico de transacciones; el borde las orquesta. El optimistic locking protege la escritura concurrente con una columna `version`.

La tabla declara la columna `version`:

```ts
// src/features/<feature>/table.ts
import { pgTable, uuid, integer } from "drizzle-orm/pg-core";

export const entities = pgTable("entities", {
  id: uuid("id").primaryKey().defaultRandom(),
  value: integer("value").notNull().default(0),
  version: integer("version").notNull().default(0), // optimistic locking
});
```

El composition root cablea el service y expone la Unidad de Trabajo:

```ts
// src/features/<feature>/composition.ts
import "server-only";
import { getDb } from "@/core/db/client";
import { makeEntityRepository } from "./repository";
import { makeEntityService as makeService } from "./service";

export function makeEntityService(tx = getDb()) {
  return makeService({ entities: makeEntityRepository(tx) });
}

// Unidad de Trabajo: el borde envuelve la operación, el service no sabe de transacciones.
export function withTransaction<T>(fn: (svc: ReturnType<typeof makeEntityService>) => Promise<T>) {
  return getDb().transaction((tx) => fn(makeEntityService(tx)));
}
```

El service compara la versión esperada y, si el repo no toca filas, lanza un `ConflictError`. Nota: en esta **variante del dial** (service como factory con métodos) la guarda `requirePermission` vive en el método del service; en el slice base vive en `use-cases.ts` — una sola regla, un solo hogar por escalón ([Convenciones §autorización](./03_referencia-convenciones-codigo.md#6-autorización)):

```ts
// src/features/<feature>/service.ts (extracto)
import "server-only";
import { ConflictError } from "@/core/errors";
import { requirePermission } from "@/core/authz";
import type { Actor } from "@/core/authz";
import type { EntityRepository } from "./ports";

export function makeEntityService(deps: { entities: EntityRepository }) {
  return {
    async update(actor: Actor, id: string, expectedVersion: number) {
      requirePermission(actor, "<feature>:write"); // deny-by-default antes de mutar
      const updated = await deps.entities.updateWithVersion(id, expectedVersion);
      if (!updated) throw new ConflictError("<feature>", id); // code 'conflict'
      return updated;
    },
  };
}
```

El repository materializa el lock en el `WHERE` e incrementa `version` atómicamente:

```ts
// src/features/<feature>/repository.ts (extracto)
import "server-only";
import { eq, and, sql } from "drizzle-orm";
import { entities } from "./table";

export function makeEntityRepository(tx: Db) {
  return {
    async updateWithVersion(id: string, expectedVersion: number) {
      const [row] = await tx
        .update(entities)
        .set({ value: sql`${entities.value} + 1`, version: sql`${entities.version} + 1` })
        .where(and(eq(entities.id, id), eq(entities.version, expectedVersion)))
        .returning();
      return row ?? null; // sin fila => la versión cambió: el service lo traduce a ConflictError
    },
  };
}
```

La Server Action orquesta la transacción y cierra revalidando. Devuelve un `FormState` serializable que `useActionState` consume en el cliente:

```ts
// src/features/<feature>/actions.ts (extracto)
"use server";
import { revalidatePath } from "next/cache";
import { getActor } from "@/core/auth/actor";
import { ConflictError } from "@/core/errors";
import { withTransaction } from "./composition";

export async function updateEntity(_prev: FormState, formData: FormData): Promise<FormState> {
  const actor = await getActor(); // Actor derivado server-side de la sesión verificada
  const id = String(formData.get("id"));
  const expectedVersion = Number(formData.get("version"));
  try {
    await withTransaction((svc) => svc.update(actor, id, expectedVersion));
    revalidatePath("/<feature>");
    return { ok: true };
  } catch (err) {
    if (err instanceof ConflictError) {
      return { ok: false, formError: "El recurso cambió en otra pestaña. Recargá e intentá de nuevo." };
    }
    throw err;
  }
}
```

Escritura de entidad **correcta**: la transacción envuelve solo Postgres y el optimistic locking resuelve la concurrencia. La frontera de consistencia termina ahí. Cuando la operación además dispara un efecto externo (correo, pago, PUT a S3), ese efecto va **después** del commit, nunca dentro de `withTransaction` (ver más abajo).

## Un efecto externo: egreso después del commit

La regla normativa —**los efectos externos van después del commit**; nada de terceros dentro de `withTransaction`, con su porqué (dual-write, pool retenido) en las [convenciones](./03_referencia-convenciones-codigo.md)— se ejecuta así.

Declarás el puerto en el dominio —en términos del dominio, no del proveedor— y lo implementás en un adaptador de egreso. El adaptador es el único que conoce el SDK, consume el `HttpClient` de `core/` (timeout obligatorio + allowlist anti-SSRF) y traduce `provider → DomainError`:

```ts
// src/features/<feature>/ports.ts (extracto): el puerto en términos del dominio.
export interface NotificationPort {
  // El dominio no sabe de Resend/SES; solo de "notificar". idempotencyKey => reintento seguro.
  notify(input: { to: string; entityId: string; idempotencyKey: string }): Promise<void>;
}
```

```ts
// src/features/<feature>/<provider>.adapter.ts: adaptador de EGRESO.
import "server-only";
import type { HttpClient } from "@/core/http/client";
import { UpstreamUnavailableError } from "@/core/errors";
import type { NotificationPort } from "./ports";

export function makeProviderNotifier(http: HttpClient): NotificationPort {
  return {
    async notify(input) {
      try {
        await http.send({
          method: "POST",
          url: "https://api.<provider>.com/v1/messages", // host validado contra la allowlist
          body: toProviderPayload(input),                 // la forma del proveedor NO sale de aquí
          idempotencyKey: input.idempotencyKey,           // el reintento no duplica el efecto
        });
      } catch (error) {
        // El SDK/firma del proveedor nunca escapa: se traduce a un DomainError de §upstream.
        throw new UpstreamUnavailableError("<provider> unavailable", { cause: error });
      }
    },
  };
}
```

El composition root lo cablea junto al service; el efecto se dispara en `actions.ts` **después** de que `withTransaction` retorna OK:

```ts
// src/features/<feature>/actions.ts (extracto): commit primero, efecto externo después.
"use server";
import { withTransaction, makeNotifier } from "./composition";

export async function confirmEntity(_prev: FormState, formData: FormData): Promise<FormState> {
  const actor = await getActor();
  const id = String(formData.get("id"));

  // 1) La frontera transaccional: solo Postgres. Si revienta, no se envió nada.
  const entity = await withTransaction((svc) => svc.confirm(actor, id));

  // 2) Recién acá, fuera de la transacción ya confirmada, el efecto externo.
  //    idempotencyKey atado a la entidad => un reintento no duplica la notificación.
  await makeNotifier().notify({ to: entity.email, entityId: entity.id, idempotencyKey: entity.id });

  revalidatePath("/<feature>");
  return { ok: true };
}
```

Disparar el efecto post-commit deja un modo de falla **at-most-once**: si el proceso muere entre el commit y el envío, la operación quedó confirmada pero el efecto se perdió. Por eso el efecto externo **debe ser idempotente** —el `idempotencyKey` atado a la entidad hace que un reintento no lo duplique, y por eso el reintento es seguro.

> Cuando perder el efecto es inaceptable y necesitás garantía *at-least-once*, el dial escala al patrón **outbox** (escribir una fila de intención en la misma transacción y procesarla con un worker). Es escalación documentada, no el default; pasa a **obligatoria** cuando un handler entrante con inbox `processed_events` debe además producir un efecto externo.

## Un webhook idempotente: dedup con `processed_events`

Un proveedor que entrega webhooks lo hace **at-least-once**: el mismo `event_id` puede llegar varias veces. Aplicar el reflejo `conflict → 409` del optimistic locking acá es **activamente incorrecto**: el proveedor interpreta cualquier no-2xx como fallo y reintenta en bucle un evento ya procesado. El webhook responde `200` a la entrega repetida y la transición de dominio es **idempotente**.

La identidad de la llamada es de máquina: se deriva server-side con `getActorFromWebhook` (verifica el HMAC del proveedor sobre el raw body), nunca del payload parseado. La tabla `processed_events` es el inbox de deduplicación; **se crea junto con la primera feature que recibe un webhook** (no pre-creada vacía), en `table.ts`, con **PK compuesta `(source, event_id)`** —nunca `event_id` solo, que produciría falso dedupe entre proveedores que reusan numeración— y una columna `attempts` para detectar el **evento veneno** (falla siempre y reentra en bucle):

```ts
// src/features/<feature>/table.ts (extracto): inbox de idempotencia.
import { pgTable, text, integer, timestamp, primaryKey } from "drizzle-orm/pg-core";

export const processedEvents = pgTable(
  "processed_events",
  {
    source: text("source").notNull(),      // proveedor/origen del webhook
    eventId: text("event_id").notNull(),   // id del evento del proveedor
    attempts: integer("attempts").notNull().default(0), // reintentos: dispara dead-letter
    processedAt: timestamp("processed_at").notNull().defaultNow(),
  },
  (t) => ({
    // PK COMPUESTA: dos proveedores distintos pueden emitir el mismo event_id.
    pk: primaryKey({ columns: [t.source, t.eventId] }),
  }),
);
```

El service inserta el evento con `ON CONFLICT DO NOTHING` **dentro de la misma `withTransaction` que aplica la transición**: el dedupe y el cambio de estado commitean juntos, atómicamente. Si el `INSERT` no afecta filas, el evento ya se procesó: corta sin re-aplicar y el borde responde `200`. La transición de dominio es idempotente y hace **short-circuit ANTES del save con guarda de `version`**: sin ese corte, una reentrega dispararía un `ConflictError` espurio contra una `version` que la primera entrega ya incrementó:

```ts
// src/features/<feature>/service.ts (extracto): la transición es idempotente.
async handleEvent(actor: Actor, event: { id: string; source: string; entityId: string }) {
  requirePermission(actor, "<feature>:write"); // actor de máquina, deny-by-default igual
  const fresh = await this.events.recordOnce(event.source, event.id); // ON CONFLICT DO NOTHING, en la misma tx
  if (!fresh) return; // ya procesado => no-op, NO error

  const entity = await this.entities.byId(event.entityId);
  if (entity.status === "confirmed") return; // ya confirmado => no-op ANTES del save con guarda de version
  // recién acá el save con optimistic locking; el short-circuit de arriba evita el ConflictError espurio
  // que una reentrega provocaría contra la version ya avanzada.
  await this.entities.markConfirmed(entity.id, entity.version);
}
```

```ts
// src/features/<feature>/repository.ts (extracto): el dedup atómico, en la tx de la mutación.
async recordOnce(source: string, eventId: string): Promise<boolean> {
  const [row] = await tx
    .insert(processedEvents)
    .values({ source, eventId }) // PK compuesta (source, event_id)
    .onConflictDoNothing()
    .returning();
  return row != null; // false => ya existía: entrega repetida
}
```

```ts
// src/features/<feature>/route.ts (extracto): el webhook siempre responde 200 al duplicado.
export async function POST(req: Request) {
  const raw = await req.text();                        // el body se lee UNA sola vez
  const actor = await getActorFromWebhook(raw, req.headers); // HMAC sobre el raw; identidad jamás del payload
  const event = parseWebhook(raw);                     // mismo raw: NUNCA se consume el body dos veces
  await withTransaction((svc) => svc.handleEvent(actor, event));
  return new Response(null, { status: 200 }); // 200 también para el evento ya procesado
}
```

> **Body una sola vez.** `await req.text()` consume el stream; leerlo de nuevo lanza `body already consumed`. Se lee el `raw` una vez y se pasa **el mismo string** a la verificación HMAC y al parseo.
>
> **Evento veneno y dead-letter.** Un evento que falla siempre incrementa `attempts`; pasado un umbral se mueve a una ruta de **dead-letter** (tabla o cola aparte) en vez de reentrar en bucle, con una **política de retención/poda** para que `processed_events` no crezca sin límite.
>
> **Efecto externo desde el webhook = outbox obligatorio.** Si el handler, además de la transición, debe producir un efecto externo (notificar, cobrar), no lo dispares post-commit suelto: el modo de falla es **at-most-once** (commit OK, proceso muere antes del envío, efecto perdido). Cuando esa pérdida es inaceptable, el **outbox** (fila de intención en la misma transacción + worker) es obligatorio, no opcional.

## Una lectura paginada: `list({ filters, page, pageSize, sort }) -> { rows, total? }`

El `service.ts` **puede** exponer lecturas ricas; no hay un `queries.ts` intermedio. La firma canónica devuelve `{ rows, total? }`, con `total` **opcional**: la paginación **offset** lo devuelve cuando la UI muestra el conteo total (un `COUNT`); la **cursor** lo **omite por contrato** (no hay `COUNT` que pagar). El `searchParamsSchema` es el contrato I/O del borde y vive en `schemas.ts`; la page lo **invoca**, no lo define:

```ts
// src/features/<feature>/schemas.ts (extracto): searchParams validados en el borde de lectura.
import { z } from "zod";

export const searchParamsSchema = z.object({
  page: z.coerce.number().int().min(1).default(1),
  pageSize: z.coerce.number().int().min(1).max(100).default(20), // .max() acotado + default
  // sort y dirección sobre una ALLOWLIST de columnas ordenables; nunca string libre a ORDER BY.
  sort: z.enum(["createdAt", "value"]).default("createdAt"),
  dir: z.enum(["asc", "desc"]).default("desc"),
  // filtros tipados del slice; nunca `any`
  status: z.enum(["active", "archived"]).optional(),
});
```

```ts
// src/app/<feature>/page.tsx (extracto): valida searchParams ANTES de invocar el service.
import { searchParamsSchema } from "@/features/<feature>/schemas";
import { makeEntityService } from "@/features/<feature>/composition";

export default async function Page({ searchParams }: { searchParams: Record<string, string> }) {
  const { page, pageSize, sort, dir, status } = searchParamsSchema.parse(searchParams); // entrada saneada
  // offset devuelve `total`; con cursor, `total` viene undefined y la UI no muestra el conteo.
  const { rows, total } = await makeEntityService().list({
    filters: { status },
    page,
    pageSize,
    sort: [{ field: sort, dir }],
  });
  return <EntityTable rows={rows} total={total} page={page} pageSize={pageSize} />;
}
```

La lectura **no** usa `withTransaction` (solo las mutaciones atómicas lo necesitan) y las filas se proyectan con el schema Zod de salida, nunca la fila de Drizzle cruda. El resto del contrato —offset por defecto y cursor como dial de performance, `total` opcional, `rows`/`total` como snapshots no atómicos— es normativo en las [convenciones](./03_referencia-convenciones-codigo.md).
