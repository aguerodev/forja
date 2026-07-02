---
id: arq.auth
titulo: Autenticación y sesión
tipo: referencia
tier: 2
audience: both
resumen: Referencia normativa de Better Auth, atributos de cookie, vida y rotación de sesión, parámetros Argon2id y derivación del Actor.
provides:
  - "módulo de auth en src/core/auth"
  - "drizzleAdapter"
  - "email/password + OAuth"
  - "Argon2id con parámetros explícitos"
  - "cookie de sesión HttpOnly + Secure + SameSite=Lax"
  - "identificador opaco de sesión"
  - "expiresIn 7d + updateAge 1d"
  - "rotación del identificador de sesión"
  - "revocación inmediata vía Postgres store"
  - "getActor / requireActor / UnauthenticatedError"
  - "tablas de auth user/session/account/verification"
  - "hashPassword / verifyPassword"
  - "resumen normativo de auth"
  - "derivadores del Actor con misma firma de salida (session, api-key, webhook)"
  - "Actor de máquina (identidad no-humana por el mismo seam, sin discriminante de origen)"
  - "anti-replay de webhook (timestamp firmado dentro del HMAC + ventana de tolerancia ~5 min; control separado del dedupe del inbox)"
  - "anti brute-force de base (throttle/lockout en login y reset)"
reads-before: [arq.convenciones]
related: [ops.resetear-password, arq.crear-feature]
---

# Referencia de auth y sesión

Cómo se autentica y cómo vive la sesión, pieza única por área con su fragmento normativo. **Better Auth** es la herramienta; el módulo vive en `src/core/auth`. El porqué de la autorización deny-by-default que esta capa alimenta está en [Referencia de las convenciones de código](./03_referencia-convenciones-codigo.md); el lugar de `src/core` en el árbol, en [Referencia de la estructura del repositorio](./02_referencia-estructura-repo.md).

## El módulo de auth (`src/core/auth`)

La autenticación es una capacidad transversal, no un slice de feature: vive en `src/core/auth` y la consumen el borde HTTP y la autorización del dominio. Better Auth se instancia una vez, tipado, con su esquema persistido en el mismo PostgreSQL del proyecto vía Drizzle:

```ts
// src/core/auth/index.ts
import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { getDb } from "@/core/db/client";
import { getConfig } from "@/core/config";

export const auth = betterAuth({
  // Persistencia sobre el mismo PostgreSQL del proyecto, vía Drizzle.
  database: drizzleAdapter(getDb(), { provider: "pg" }),

  // Email/password con hashing Argon2id (ver "Hashing de contraseñas").
  emailAndPassword: { enabled: true },

  // OAuth: OPCIONAL por proyecto — email/password es el piso; el bloque
  // socialProviders se agrega solo si el proyecto lo pide (shorter no lo usa).
  // Cada proveedor toma sus credenciales de `config`, nunca literales.
  socialProviders: {
    "<proveedor-oauth>": {
      clientId: getConfig().oauth_client_id,
      clientSecret: getConfig().oauth_client_secret,
    },
  },

  // Cookie y ciclo de vida de la sesión (ver secciones siguientes).
  session: {
    expiresIn: 60 * 60 * 24 * 7, // 7 días de vida máxima (parametrizable)
    updateAge: 60 * 60 * 24, // rotación: se refresca si tiene > 1 día (parametrizable)
    cookieCache: { enabled: false },
  },
  advanced: {
    // Prefijo de cookie derivado del nombre de la app (${APP}).
    cookiePrefix: "${APP}",
    defaultCookieAttributes: {
      httpOnly: true,
      secure: true,
      sameSite: "lax",
    },
  },
});

export type Session = typeof auth.$Infer.Session;
```

`src/core/auth` expone `auth` (la instancia) y los helpers de derivación del `Actor`. Nada fuera de este módulo construye sesiones a mano ni hashea contraseñas: el resto de la aplicación pide el `Actor` ya verificado.

## La cookie de sesión

La sesión viaja en una cookie con tres atributos innegociables, fijados en `defaultCookieAttributes`:

- **`HttpOnly`** — el JavaScript del cliente no puede leerla; queda fuera del alcance de un XSS.
- **`Secure`** — solo se transmite sobre HTTPS.
- **`SameSite=Lax`** — no se envía en peticiones cross-site de terceros, lo que corta el CSRF de navegación; deja pasar la navegación top-level legítima (un enlace entrante) sin romper OAuth.

El identificador de sesión es opaco: no transporta datos del usuario ni permisos. Todo lo que la autorización necesita se carga server-side del store de sesión/usuario, nunca de la cookie.

## Expiración y rotación

La sesión tiene una **vida máxima** (`expiresIn`) y una **rotación** (`updateAge`). Los valores `7d` / `1d` son los normativos por defecto, parametrizables según el perfil de riesgo del proyecto:

- `expiresIn` (7 días) es el techo absoluto: pasado ese plazo desde su creación, la sesión caduca y exige reautenticación.
- `updateAge` (1 día) renueva la ventana de la sesión activa: al usar una sesión con más de `updateAge` de antigüedad, Better Auth emite un identificador fresco y extiende su expiración. Una sesión en uso continuo se mantiene viva; una inactiva caduca contra el techo. La rotación del identificador acota la ventana en que una cookie filtrada sigue siendo útil.

El cierre de sesión y la revocación invalidan el registro en el store; al persistirse las sesiones en Postgres (ver "Tablas de sesión y usuario"), la invalidación es inmediata y consultable, no depende de que expire un token autocontenido.

## Hashing de contraseñas (Argon2id)

Las contraseñas de email/password se hashean con **Argon2id**, el modo híbrido resistente tanto a ataques de canal lateral como a GPU. Los parámetros son explícitos —no se dejan a un default implícito— y se alojan en el módulo de auth. Los valores siguientes son el perfil interactivo de OWASP; normativos por defecto y parametrizables si el hardware lo justifica:

```ts
// src/core/auth/password.ts
import { hash, verify } from "@node-rs/argon2";

// Parámetros normativos (perfil interactivo OWASP).
const ARGON2ID = {
  algorithm: 2, // Argon2id
  memoryCost: 19_456, // 19 MiB
  timeCost: 2, // iteraciones
  parallelism: 1, // grado de paralelismo
} as const;

export function hashPassword(plain: string): Promise<string> {
  return hash(plain, ARGON2ID);
}

export function verifyPassword(digest: string, plain: string): Promise<boolean> {
  return verify(digest, plain);
}
```

Argon2id protege contra el **cracking offline** (un atacante con la tabla de hashes robada), pero **no** contra el **brute-force / credential-stuffing online** —probar credenciales contra el endpoint vivo—, amenaza presente desde el primer día. Por eso los endpoints de **auth humana** (login, password-reset) y los **fallos de verificación de credencial** llevan un **throttle/lockout de base** (control de base, no del dial): limitar intentos por identidad y por origen. La auth de máquina que abren los derivadores (API key, webhook) lleva también un **límite básico**. El motor de rate limiting **distribuido** —cuota fina, ventana deslizante compartida entre instancias— sigue siendo escalación del dial; el throttle de base no.

El hash y su verificación viven **solo** aquí; ningún servicio de dominio ni adaptador conoce el algoritmo. La contraseña en claro nunca se loguea ni se serializa: cae bajo la regla de telemetría que censura `password` y sus variantes, definida en las [convenciones de código](./03_referencia-convenciones-codigo.md). Con la auth de máquina, esa censura se **extiende** a todo secreto que cruza este módulo: el header `Authorization`, las API keys (secreto crudo y prefijo/key-id), `webhook_secret`, las firmas HMAC y cualquier clave que termine en `*_secret`. Lo que entra al canal de telemetría sale redactado, sin excepción.

## El `Actor` se deriva server-side

La autorización del dominio opera sobre un `Actor` —un id opaco y un conjunto de permisos concedidos, definido en las [convenciones de código](./03_referencia-convenciones-codigo.md)—. Ese `Actor` se construye **siempre** server-side a partir de una credencial **verificada**, y **nunca** se acepta del cuerpo, las cabeceras o los parámetros del request como identidad afirmada: una identidad provista por el cliente es una identidad falsificable.

No toda identidad es un humano con navegador, pero el `Actor` **no lleva un discriminante de origen**. Una máquina autenticada por una credencial de sistema (API key, webhook firmado) produce **el mismo** `Actor` que un humano autenticado por sesión: un id opaco y su conjunto de permisos. La frontera entre auth humana y no-humana es un **seam** que vive en los *derivadores*, no en un campo propagado al `Actor`. La forma canónica vive en las convenciones; aquí basta su contorno:

```ts
// Contorno del Actor (definición canónica en core/authz).
// Sin discriminante de origen: un actor de máquina es solo un Actor
// con su set de permisos. Nada en el dominio ramifica por "tipo".
type Actor = { id: string; permissions: ReadonlySet<string> };
```

La invariante es única: **el id y los permisos salen de una credencial verificada server-side, jamás del request**. Lo único que cambia entre humano y máquina es *qué* credencial se verifica y *cómo*, y eso se resuelve dentro del derivador antes de construir el `Actor`. Si un consumidor necesitara ramificar por origen (por ejemplo, saltar la protección CSRF de sesión en un camino máquina-a-máquina), esa rama vive en el **borde que elige el derivador**, no en un discriminante que cada `service.ts` tendría que conocer. No hay `tenantId` ni atributos de organización en el `Actor`: el resto es escalación consciente (ver "Dial").

### Derivadores: misma firma de salida, distinta credencial de entrada

Cada origen tiene su **derivador**, y todos devuelven el **mismo** tipo `Actor`. Esa es la pieza apalancada: `requirePermission` y el deny-by-default no saben —ni deben saber— de qué camino vino el `Actor`. Sumar un origen es sumar un derivador, sin tocar la autorización.

```ts
// src/core/auth/actor.ts
import { headers } from "next/headers";
import { auth } from "./index";
import type { Actor } from "@/core/authz";

// HUMANO — deriva el Actor de la sesión Better Auth verificada.
// Reemplaza al antiguo getActor(): el nombre explicita el origen.
export async function getActorFromSession(): Promise<Actor | null> {
  const session = await auth.api.getSession({ headers: await headers() });
  if (!session) return null;

  // Los permisos se cargan del store de sesión/usuario, no de la cookie.
  const permissions = await loadPermissions(session.user.id);

  return {
    id: session.user.id, // id opaco; nunca el email
    permissions: new Set(permissions),
  };
}

// Variante estricta para casos de uso humanos que exigen identidad.
export async function requireActor(): Promise<Actor> {
  const actor = await getActorFromSession();
  if (!actor) throw new UnauthenticatedError();
  return actor;
}
```

El borde HTTP obtiene el `Actor` y lo pasa al servicio; **el caso de uso** aplica la guarda `requirePermission(actor, ...)` antes de cualquier cambio de estado (`use-cases.ts` es el hogar único de la guarda; `service.ts` solo cablea — ver [Convenciones](./03_referencia-convenciones-codigo.md#6-autorización)). La autorización es deny-by-default: un permiso ausente del conjunto es un permiso denegado, así que un actor —humano o máquina— sin el permiso explícito no pasa.

### Actores de máquina (seam, no implementación)

Dos derivadores más comparten la firma de salida y autentican credenciales de sistema. El **seam** es que `requireActor`/`Actor` no hardcodean la cookie de sesión y **pueden** representar identidad de máquina; esa es la regla que se documenta hoy. Los cuerpos de abajo son el contorno que cada proyecto completa **cuando expone superficie máquina-a-máquina real**, no de forma preventiva:

- **`getActorFromApiKey(request)` — API key.** Una API key tiene **dos partes**: un **key-id público** (un prefijo, no secreto, que viaja en claro y permite el lookup) y un **secreto** de alta entropía. El derivador lee la credencial del header `Authorization`, **busca el registro por key-id** (no por el secreto) y **compara el hash del secreto en tiempo constante** sobre `Buffer` (nunca string hex, que filtra por longitud y comparación no constante). Se guarda **solo el hash del secreto** con **SHA-256**, no con el Argon2id de `password.ts`: una API key es un secreto generado por el sistema con >=256 bits de entropía, no una contraseña humana débil, y Argon2id es deliberadamente lento (corre en *cada* request y mataría la latencia). La generación está normada: **CSPRNG con >=256 bits**, **prefijo documentado**, y el valor en claro se muestra **una sola vez** en la emisión. Es la forma única de API key del proyecto —esta sección es el hogar normativo de esa implementación; las [convenciones de código](./03_referencia-convenciones-codigo.md) solo documentan el seam del `Actor`—. Devuelve un `Actor` de máquina con los permisos declarados al emitir la key.

- **`getActorFromWebhook(raw, headers)` — webhook firmado.** Verifica la **firma HMAC** del proveedor sobre el **cuerpo crudo** con un secret de config, en comparación de tiempo constante, antes de confiar en el payload. Recibe el `raw` ya leído por el borde —**no** consume el `Request`—, porque ese cuerpo debe parsearse después y el body de un `Request` se consume **una sola vez**. La identidad de la máquina sale de la firma verificada, nunca del body. El **anti-replay** es un control **separado** del dedupe idempotente del inbox: valida un **timestamp firmado DENTRO del HMAC** contra una **ventana de tolerancia (~5 min)**, de modo que una petición capturada no se pueda reproducir más tarde aunque la firma sea válida. El detalle del patrón de webhook entrante (dedupe idempotente, inbox) vive en la referencia del borde HTTP.

```ts
// src/core/auth/actor.ts (continuación) — seam de auth no-humana.
import { timingSafeEqual, createHash } from "node:crypto";
import type { Actor } from "@/core/authz";

// MÁQUINA — API key: key-id público + secreto; hash SHA-256 del secreto
// y comparación en tiempo constante sobre Buffer (nunca string hex).
export async function getActorFromApiKey(request: Request): Promise<Actor | null> {
  const presented = readApiKey(request.headers); // del header Authorization
  if (!presented) return null;

  const record = await findApiKeyById(presented.keyId); // lookup por key-id público
  if (!record) return null;

  const digest = createHash("sha256").update(presented.secret).digest(); // Buffer
  if (!timingSafeEqual(digest, record.secretHash)) return null; // tiempo constante

  return {
    id: record.id, // id opaco de la key; nunca el secreto
    permissions: new Set(record.scopes), // permisos declarados al emitir
  };
}

// MÁQUINA — webhook: firma HMAC + anti-replay (timestamp firmado, ventana ~5 min).
// Recibe el raw ya leído por el borde; NO consume el Request (eso lo hace el borde,
// una sola vez, y reparte el mismo raw a este derivador y al parser).
const REPLAY_WINDOW_MS = 5 * 60 * 1000;

export function getActorFromWebhook(raw: string, headers: Headers): Actor | null {
  if (!verifyHmac(raw, headers, getConfig().webhook_secret)) return null;

  // Anti-replay: el timestamp viaja firmado DENTRO del HMAC, no como header suelto.
  const signedAt = readSignedTimestamp(headers); // cubierto por la firma verificada
  if (Math.abs(Date.now() - signedAt) > REPLAY_WINDOW_MS) return null;

  return {
    id: "<provider>:webhook", // identidad del emisor, no del body
    permissions: new Set(WEBHOOK_SCOPES),
  };
}
```

`requirePermission` recibe cualquier `Actor` sin distinguir su origen: el deny-by-default sigue siendo el **único** punto de autorización. Un derivador que falla devuelve `null` (o lanza el error de autenticación correspondiente en su variante estricta) y el request muere antes de tocar el dominio.

```ts
// src/features/<feature>/route.ts (Route Handler): el Actor entra ya verificado.
import { requireActor } from "@/core/auth/actor";
import { makeFeatureService } from "./composition";

export async function POST(request: Request) {
  const actor = await requireActor(); // identidad server-side, no del body
  const input = FeatureCommand.parse(await request.json());
  const result = await makeFeatureService().execute(input, actor);
  return Response.json(FeatureView.parse(result));
}
```

```ts
// En una Server Action ('use server') el patrón es idéntico:
// el Actor sale de requireActor(), no de un campo del FormData.
import { requireActor } from "@/core/auth/actor";

export async function featureAction(/* ... */) {
  const actor = await requireActor();
  // ... makeFeatureService().execute(input, actor)
}
```

En el borde de un **webhook** el cuerpo se lee **una sola vez** y el mismo `raw` alimenta la verificación de firma y el parseo. El body de un `Request` es un stream de un solo uso: consumirlo dos veces (por ejemplo `request.text()` para la firma y luego `request.json()` para el payload) lanza `body already consumed`.

```ts
// src/features/<feature>/webhook/route.ts
import { getActorFromWebhook } from "@/core/auth/actor";
import { parseWebhook } from "./parse";
import { makeFeatureService } from "../composition";

export async function POST(request: Request) {
  const raw = await request.text(); // se lee UNA sola vez

  const actor = getActorFromWebhook(raw, request.headers); // firma + anti-replay
  if (!actor) return new Response("invalid signature", { status: 401 });

  const event = parseWebhook(raw); // mismo raw; no se vuelve a tocar el Request
  const result = await makeFeatureService().handleEvent(event, actor);
  return Response.json(result);
}
```

## Tablas de sesión y usuario (Drizzle)

Better Auth persiste su esquema sobre el mismo PostgreSQL del proyecto vía el adaptador Drizzle. Las tablas (`user`, `session`, `account`, `verification`) se declaran en `src/core/auth/schema.ts` con `pgTable`, igual que cualquier otra tabla, y `drizzle-kit` las recoge para generar migraciones versionadas:

```ts
// src/core/auth/schema.ts
import { boolean, pgTable, text, timestamp } from "drizzle-orm/pg-core";

export const user = pgTable("user", {
  id: text("id").primaryKey(),
  email: text("email").notNull().unique(),
  emailVerified: boolean("email_verified").notNull().default(false),
  createdAt: timestamp("created_at").notNull().defaultNow(),
});

export const session = pgTable("session", {
  id: text("id").primaryKey(),
  userId: text("user_id")
    .notNull()
    .references(() => user.id, { onDelete: "cascade" }),
  expiresAt: timestamp("expires_at").notNull(),
  token: text("token").notNull().unique(),
  createdAt: timestamp("created_at").notNull().defaultNow(),
  updatedAt: timestamp("updated_at").notNull().defaultNow(),
});

// `account` (credenciales y vínculos OAuth) y `verification` (tokens de email)
// completan el esquema; drizzle-kit las versiona junto con el resto.
```

Que las sesiones vivan en Postgres da revocación inmediata y deja la identidad consultable con las mismas herramientas que el resto del modelo de datos. El `scope` `auth` de la migración entra por el flujo de migraciones del proyecto; no hay un canal de esquema aparte.

## Resumen normativo

| Dimensión | Norma |
| --- | --- |
| Herramienta | Better Auth, módulo único en `src/core/auth` |
| Persistencia | PostgreSQL del proyecto vía adaptador Drizzle |
| Métodos | email/password + OAuth |
| Hashing | Argon2id con parámetros explícitos en `password.ts` |
| Cookie | `HttpOnly` + `Secure` + `SameSite=Lax`, identificador opaco |
| Sesión | `expiresIn` (techo) + `updateAge` (rotación), revocable en el store |
| `Actor` | `{ id, permissions }` sin discriminante de origen; derivado server-side de credencial verificada; jamás del request |
| Derivadores | `getActorFromSession` (sesión) · `getActorFromApiKey` (key-id + secreto, SHA-256 del secreto) · `getActorFromWebhook(raw, headers)` (HMAC + anti-replay) — misma firma de salida |
| Autorización | Permisos del store + `requirePermission` deny-by-default, ciego al origen del actor |
| Anti brute-force | Throttle/lockout en auth humana (login/password-reset) y límite básico en endpoints de máquina — control de base, no Argon2id |

## Dial: escalaciones conscientes

Lo siguiente NO se implementa por defecto; se documenta como escalación con su disparador para que la decisión sea deliberada:

- **Plugins `bearer` / `organization` de Better Auth.** Better Auth ofrece plugins oficiales para tokens bearer y para modelar organizaciones/membresías. **Disparador:** cuando la API máquina-a-máquina necesite tokens bearer rotables emitidos por el propio Better Auth en vez de API keys propias, o cuando aparezca multi-tenancy real (organizaciones, membresías, roles por org). Hasta entonces, el seam del derivador de máquina y los derivadores propios alcanzan; adoptar el plugin `organization` es lo que introduce el `tenantId`/`orgId` que hoy se omite a propósito. Adoptarlos evita rodar criptografía/persistencia propia, a cambio de acoplar el modelo de identidad a las abstracciones del plugin.
- **Ciclo de vida completo de API keys** (tabla, emisión, rotación, revocación inmediata espejando el store de sesión). **Disparador:** exponer la primera superficie pública a un consumidor externo. El derivador `getActorFromApiKey` es el seam; su store y su flujo de emisión/rotación son la implementación que se abre con el primer partner.
- **Motor de rate limiting distribuido** (cuota fina por clave, ventana deslizante compartida entre instancias, store dedicado). **Disparador:** correr en más de una instancia o necesitar cuotas finas por consumidor. El throttle/lockout de base de la auth humana y de máquina **no** está aquí: es control de base (ver "Hashing de contraseñas"); lo que el dial difiere es el motor compartido entre réplicas.

> El procedimiento break-glass para resetear la contraseña de un usuario reutilizando este mismo hasher Argon2id está en [Resetear la contraseña de un usuario](../operaciones/11_how-to-resetear-password.md).
