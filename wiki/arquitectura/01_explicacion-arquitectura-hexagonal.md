---
id: arq.hexagonal
titulo: Arquitectura hexagonal
tipo: explicacion
tier: 2
audience: both
resumen: Las tres decisiones anidadas (monolito modular, vertical slices, núcleo hexagonal por feature) y los seis contratos que las hacen cumplir.
provides:
  - "monolito modular"
  - "Vertical Slice Architecture / vertical slice"
  - "feature como módulo autocontenido por contexto de negocio"
  - "núcleo hexagonal / puertos y adaptadores"
  - "puerto (interface TypeScript que define el dominio)"
  - "adaptador (implementación concreta de un puerto)"
  - "use-cases.ts (casos de uso puros: reciben el puerto y las dependencias no deterministas por argumento)"
  - "service.ts como punto de composición (pre-cablea el adaptador concreto en los use cases; server-only; fachada única del borde)"
  - "composition root formal y Unidad de Trabajo withTransaction(fn) — entrada del dial"
  - "layering intra-slice (cadena route -> service -> use-cases -> domain)"
  - "cuatro caminos del borde (lectura vía Server Component, mutación vía actions.ts, API externa vía route.ts, egreso a terceros vía adapter)"
  - "borde HTTP"
  - "seis contratos ejecutables de dependency-cruiser"
  - "public.ts como única superficie pública cross-feature"
  - "el código grita el dominio"
  - "el punto de composición como chokepoint de instrumentación del egreso"
reads-before: [fund.principios]
related: [fund.glosario, proc.trabajo-ia]
---

# La arquitectura por dentro: monolito modular, vertical slices y núcleo hexagonal

Organización del código: un solo desplegable partido en features, cada feature con un núcleo puro rodeado de adaptadores, y una regla de dependencias que un linter hace cumplir. Tres decisiones encajadas, cada una con su razón. Fuente de verdad de la forma del código; el inventario de qué archivo hay en una feature está en la [Referencia de la estructura del repositorio](./02_referencia-estructura-repo.md). Todo concreta un principio: [la arquitectura se optimiza para el bucle de la IA](../fundamentos/01_explicacion-principios.md#la-arquitectura-optimiza-el-bucle-de-la-ia).

## Primera decisión: un monolito, no microservicios

**Monolito modular**: un único desplegable con fronteras internas fuertes entre módulos. Los microservicios fragmentan el contexto: un cambio que cruza tres servicios cruza tres repos y en ninguno se ve el sistema entero. Un solo desplegable entrega el sistema completo como espacio navegable; seguir una llamada de punta a punta es leer, no saltar entre repos. Con Next.js App Router es además **full-stack**: UI server-side, Route Handlers y Server Actions en el mismo desplegable, sin partir front y back en dos artefactos. Romper el monolito en servicios es una escalación del dial, no el punto de partida. “Modular” evita que degenere: por fuera es uno, por dentro está cortado en módulos que no se entrometen entre sí.

## Segunda decisión: organizar por feature, no por capa

El código se organiza **por feature** (contexto de negocio), no por capa técnica. Es **Vertical Slice Architecture**: la estructura “grita” el dominio (`orders/`, `billing/`), no la técnica (`controllers/`, `services/`). Cada feature es un módulo autocontenido con su dominio, sus casos de uso, sus adaptadores y su borde HTTP. Organizar por capa esparce una feature por todo el árbol y obliga a abrir media docena de directorios; organizar por feature acota el cambio a **una carpeta**: “¿dónde va esto?” deja de ser decisión, el agente carga poco y rompe poco fuera de ese límite. El árbol de routing de Next vive en `src/app/`, solo cableado fino al framework (`src/app/api/<feature>/route.ts` reexporta los handlers del slice); TODA la lógica de la feature vive en `src/features/<feature>/`.

## Tercera decisión: dentro de cada feature, un núcleo hexagonal

La carpeta resuelve el “dónde”; el “cómo se ordena por dentro” es la **regla hexagonal** (puertos y adaptadores): el dominio en el centro no sabe nada del exterior, y el exterior se conecta a él por puertos. En capas:

```
src/features/<feature>/                 dependencias →  hacia adentro
┌───────────────────────────────────────────────────────────────┐
│  route.ts      Next: Route Handlers (GET/POST)   ← borde HTTP  │
│  actions.ts    Next: Server Actions ("use server") ← borde     │
├───────────────────────────────────────────────────────────────┤
│  service.ts    punto de composición: pre-cablea el adaptador   │
│                en los use cases (server-only)     ← fachada    │
├───────────────────────────────────────────────────────────────┤
│  use-cases.ts  casos de uso + autorización        ← PURO       │
│  domain.ts     entidades + reglas                 ← PURO       │
│  ports.ts      interfaces de los puertos          ← PURO       │
└───────────────────────────────────────────────────────────────┘
        ▲ implementa puertos
┌───────┴───────────────────────────────────────────────────────┐
│  repository.ts   adaptador Drizzle/pg   │  table.ts (Drizzle)  │
│  <provider>.adapter.ts   adaptador de EGRESO (puerto a 3ro)    │
│  schemas.ts      Zod (contrato I/O del borde, → OpenAPI 3.1)   │
└────────────────────────────────────────────────────────────────┘
```

En el núcleo puro la suite corre en milisegundos sin levantar BD: el bucle apretado donde el agente prueba, ve el resultado y corrige sin esperar. Un dominio enredado con la infraestructura mata esa velocidad.

## Qué hace cada archivo

Cada archivo marca una frontera de dependencias; esas fronteras mantienen el núcleo puro y el borde fino. Los nombres son fijos por capa (scaffolded por Plop).

- **`domain.ts`** — Entidades, objetos de valor, invariantes y errores de dominio de la feature. TypeScript puro: no importa Next, Drizzle, `pg` ni Zod. Centro del hexágono.
- **`ports.ts`** — Las **interfaces** de los puertos que la feature necesita del exterior (repositorio, reloj, mailer). Solo referencia tipos del dominio. Se separan en su propio archivo por legibilidad, pero siguen siendo capa de dominio pura.
- **`use-cases.ts`** — Los casos de uso, como **funciones puras**: reciben el `Actor`, el input ya validado, el **puerto** (la interface de `ports.ts`) y toda dependencia no determinista (reloj, generador de ids) **por argumento**. Aquí vive la **autorización** (`requirePermission`, deny-by-default antes de mutar estado). Al no importar infraestructura, se testean en milisegundos con un fake del puerto, sin `server-only` ni mocks de framework.
- **`service.ts`** — El **punto de composición** del slice y su fachada: módulo **server-only** que instancia el adaptador concreto (p. ej. el repositorio, como singleton del proceso) y exporta funciones con la firma del caso de uso ya cableado (`createLink(actor, input)` llama a `createLinkUseCase(actor, input, repo, () => uuidv7())`). Es el ÚNICO módulo del slice que el borde importa: `route.ts` y `actions.ts` jamás tocan `repository.ts` ni `use-cases.ts` directo. En tests, el fake se inyecta llamando al use case directamente: `createLinkUseCase(actor, input, fakeRepo, fakeIds)` — sin overrides mágicos.
- **`repository.ts`** — Adaptador que implementa los puertos sobre Drizzle/`pg`. Infraestructura: el dominio define el puerto, el repositorio lo cumple. NUNCA deja escapar la excepción del proveedor: traduce el `DatabaseError` de `pg` a un error del dominio. **Server-only**: importa `server-only` en el tope.
- **`<provider>.adapter.ts`** — Adaptador de **egreso**: implementa un puerto de `ports.ts` sobre el SDK o la API de un tercero (mailer, pasarela de pago, object storage, ERP), distinto de `repository.ts` (que es el adaptador de la BD). El SDK, la firma y el vocabulario del proveedor NO salen de aquí: traduce la excepción del tercero a un error del dominio, igual que el repositorio. **Server-only**: importa `server-only` en el tope. SOLO existe si la feature integra un tercero. Se vuelve **hogar canónico** —con rama de Plop y espejo de test en `tests/`— recién por la regla de tres, tras la segunda integración de egreso real; la primera es solo la interface en `ports.ts` y su adaptador.
- **`table.ts`** — Tabla Drizzle (`pgTable`). Modelo de persistencia separado del dominio a propósito; drizzle-kit lo lee para generar migraciones. SOLO existe si la feature persiste.
- **`schemas.ts`** — Schemas Zod registrados con `.openapi()`: contrato de entrada y salida de la **API externa** (`route.ts`) e insumo de Schemathesis. Define la forma de los datos en la frontera de transporte pública.
- **`route.ts`** — **API externa**: Route Handlers (`GET`/`POST`/...) para la API pública, consumidores externos y webhooks. Es lo que se registra en el contrato OpenAPI 3.1 y lo que Schemathesis fuzzea. Lo más fino posible; transporta lógica, no la contiene.
- **`actions.ts`** — Server Actions (`"use server"`): borde de **mutación** disparado desde forms y eventos del cliente. Cada action valida la entrada, invoca el service, y **termina con `revalidatePath`/`revalidateTag`** del recurso afectado; devuelve a la UI un **estado serializable** (para `useActionState`), traduciendo un `DomainError` a un estado de form/campo, nunca crudo. Son RPC internas: NO se registran en el contrato OpenAPI (se cubren con tests de integración). No se usan para LEER datos.
- **`composition.ts`** — **NO es parte del slice base: es una escalación del dial.** Cuando el cableado plano de `service.ts` deja de alcanzar —una operación debe tocar **varios repos en una misma transacción** (Unidad de Trabajo `withTransaction(fn)` que pasa el handle `tx` a los participantes), o un puerto gana su **segunda implementación real** y hace falta elegir por entorno—, el wiring se extrae a un `composition.ts` con factories por request. Hasta ese síntoma, un archivo de factories para un solo repo singleton es indirección sin pago: el punto de composición ES `service.ts`.
- **`public.ts`** — **Superficie pública** de la feature: el ÚNICO archivo que otra feature puede importar. Reexporta los tipos del dominio que cruzan la frontera y la **interfaz** del servicio (no la implementación), nunca internos (`domain`, `repository`, `table`, `composition` quedan privados). Es el carve-out del contrato cross-feature: sin `public.ts`, ninguna feature ve nada de otra.

El borde reparte cuatro caminos. Tres son **entrantes** —nacen de un request HTTP (navegador, consumidor externo, webhook) y terminan en una respuesta—, cada uno con su responsabilidad fija:

- **LECTURA** → el Server Component lee llamando a la **función del service directamente** dentro de `page.tsx` (`await listMyLinks(actor)`). La lectura no pasa por `actions.ts` ni por `route.ts`: el service alcanza, sin un archivo de queries intermedio.
- **MUTACIÓN** → `actions.ts` (`"use server"`), disparada por forms y eventos; valida, invoca el service, revalida con `revalidatePath`/`revalidateTag` y devuelve estado serializable a la UI.
- **API EXTERNA** → `route.ts` (Route Handlers) para API pública, consumidores externos y webhooks; es lo que va al contrato OpenAPI y lo que Schemathesis fuzzea.

El **cuarto camino es de dirección opuesta: SALIENTE**. Los tres anteriores reciben; este llama hacia afuera:

- **EGRESO** → toda llamada **saliente** a un tercero (mailer, pasarela de pago, object storage, ERP) sale por un **puerto declarado en `ports.ts`** y la cumple un adaptador `<provider>.adapter.ts`. El dominio define la interfaz; el adaptador trae el SDK. El SDK, la firma y el vocabulario del proveedor **nunca salen del adaptador**: `domain.ts` y `service.ts` solo conocen el puerto y reciben/lanzan errores del dominio. Es el mismo patrón puertos/adaptadores que ya aísla la BD, aplicado al borde saliente.

  El hogar `<provider>.adapter.ts` se **canoniza por la regla de tres**, no por anticipación: la PRIMERA integración de egreso es solo la **interface en `ports.ts`** y su adaptador concreto; recién tras la **segunda ocurrencia real** en el repo el hogar se vuelve forma canónica —rama de Plop, regex de dependency-cruiser, espejo de test en `tests/`—. Nombrar el patrón no es generar el scaffolding: antes del segundo caso, el seam vive en el puerto y nada más.

El egreso es asimétrico respecto de los tres entrantes. Aquellos son request/response y la doctrina los cubre con rigor (validación Zod, contrato OpenAPI, fuzzing); el saliente es el borde más frágil —parseo de la respuesta del tercero, traducción `provider → DomainError`, timeout, reintento— donde un descuido cuelga el request o agota el pool. Por eso toda llamada saliente atraviesa un puerto `HttpClient` de `src/core/http`, con **`timeout` como parámetro requerido en la firma del puerto** (lo omite y `tsc` rompe el build; no es un default de runtime). Es un **gate**, no prosa: el contrato `egress-through-httpclient` de dependency-cruiser **prohíbe importar primitivas de red crudas** (`fetch` directo, `undici`, `axios`, `node:http`/`node:https`) fuera de `src/core/http`. Ningún adaptador habla con la red por su cuenta; pasa por el puerto o no compila.

El mismo puerto **expone un hook de validación de host/IP** anti-SSRF, cuyo enforcement se activa SOLO cuando la URL de destino deriva de datos de usuario o de un tercero; la política completa (resolver-validar-pinear la IP, redirects, rangos bloqueados) es normativa en las [convenciones](./03_referencia-convenciones-codigo.md#el-borde-de-egreso-el-puerto-httpclient).

Que TODA llamada saliente pase por un puerto convierte al **punto de composición (`service.ts`) en el chokepoint** de las preocupaciones transversales del egreso. Ahí, al cablear el adaptador concreto en los use cases, se lo envuelve con un decorador (`withTelemetry`/`instrumentedPort`) que emite latencia y `outcome`. El dominio y los use cases no se enteran: la instrumentación nace en un único lugar, garantizado por máquina (el contrato `domain-stays-pure` impide que el SDK del proveedor se filtre a otra capa). La idempotencia, en cambio, **no vive en la firma del puerto genérico de transporte**: es un parámetro de la operación específica del adaptador del proveedor (un header `Idempotency-Key`), no del `HttpClient`. La regla normativa del egreso —los efectos externos van **después** del commit, jamás dentro de `withTransaction`— se desarrolla en las convenciones; aquí basta retener que la frontera de consistencia termina en Postgres y el egreso ocurre fuera de ella.

Los rieles del dial (escalaciones conscientes, no el default): cuando el egreso necesita **garantía de entrega** más allá del request, el salto es un **outbox transaccional** —escribir el cambio de dominio y una fila de outbox en la misma `withTransaction`, con un relay que reintenta—; ese salto arrastra al anterior: exige haber extraído primero la Unidad de Trabajo (`composition.ts` + `withTransaction`), que entrega el `tx` a cualquier repo participante. Para el caso inverso —empujar datos al cliente a medida que ocurren— el riel barato es una **suscripción vía SSE** (un `route.ts` marcado como streaming, fuera del contrato OpenAPI/Schemathesis), separada de los WebSockets. Ambos se documentan en el dial con su disparador; ninguno es punto de partida.

Cada feature aloja **su propia presentación** en `src/features/<feature>/components/`: los componentes React PROPIOS de la feature (server y client). Distinta de `src/components/ui/` global, que aloja primitivas genéricas (shadcn) reutilizables por cualquier feature. La regla: genérico y reutilizable → `src/components/ui/`; específico de un contexto de negocio → `features/<feature>/components/`. Así la presentación no se dispersa fuera del slice.

El código transversal —pool y cliente Drizzle, config, errores base, traducción error→HTTP— vive en `src/core/` (`config.ts`, `errors.ts`, `authz.ts`, `db/client.ts`, `http/errors.ts`), nunca dentro de una feature. El árbol de routing de Next (`src/app/`) es el cableado fino al framework: solo bindings al enrutador, sin lógica de negocio. Las primitivas de dominio que de verdad comparten varias features van en `src/shared/`, con moderación: compartir de más reacopla lo que la organización por feature separó.

## La regla de dependencias, y por qué la verifica una máquina

Todo descansa sobre una regla innegociable: **las dependencias apuntan siempre hacia adentro**. El **layering intra-slice** la concreta como una cadena fija de capas:

- **El borde** (`route.ts`, `actions.ts`) solo importa las funciones de **`service.ts`**; nunca toca el repositorio, los use cases ni el dominio directamente.
- **Los use cases** (`use-cases.ts`) orquestan **domain** y **ports**; no conocen HTTP ni Drizzle, y reciben sus dependencias por argumento — por eso son puros y testeables en milisegundos.
- **El service** es el punto de composición: fija el adaptador concreto en cada use case y expone la fachada. Cuando una operación necesita atomicidad multi-repo, ese es el disparador para extraer un `composition.ts` con `withTransaction(fn)` (dial).
- **El repository** implementa el puerto declarado en `ports.ts`; es el dominio quien define la interfaz y el adaptador quien la cumple.
- **El dominio** (`domain.ts`, `ports.ts`, `use-cases.ts`) no importa NADA del borde ni de la infraestructura: ni Next, ni Drizzle, ni `pg`, ni Zod, ni los adaptadores del propio slice.

En resumen: `route.ts / actions.ts → service.ts → use-cases.ts → domain.ts / ports.ts`, con `repository.ts → ports.ts` (implementa). Los adaptadores dependen del dominio y nunca al revés.

Segunda cláusula: **las features no importan los internos de otras features**; si dos necesitan hablar, lo hacen por un **contrato explícito y único: el `public.ts` del proveedor**. Una feature consumidora solo puede importar `features/<otra>/public.ts` —jamás su `domain`, `service`, `repository` ni `table`—. Patrón recomendado para una dependencia cross-feature: el slice consumidor declara un PUERTO en su `ports.ts`, un adaptador lo implementa llamando al `public.ts` del proveedor, y su `service.ts` lo cablea; el acoplamiento queda detrás de un puerto, igual que la BD. Esto se **verifica, no se recuerda**: **dependency-cruiser** corre en CI y rompe el build si un `domain.ts` importa Drizzle o si una feature mete mano en internos de otra. Conecta con el principio [los guardarraíles que importan son ejecutables](../fundamentos/01_explicacion-principios.md#los-guardarraíles-que-importan-son-ejecutables): una arquitectura que se respeta siempre, incluso cuando quien escribe el código es un agente que no leyó este documento.

Seis contratos ejecutables imponen el borde —no prosa que se recuerda, sino gates de CI que rompen el build:

1. **`domain-stays-pure`** (allowlist): `domain.ts` y `ports.ts` solo pueden importar su propio dominio, `core/errors` y `shared` puro; cualquier otro destino —un framework (`next`), el ORM (`drizzle-orm`), el driver (`pg`), la validación de borde (`zod`) o un adaptador del propio slice— cae como violación por defecto. Lo no permitido explícitamente rompe el build.
2. **`inward-layering`** (hacia adentro): dentro del slice el borde no se saltea el `service` para tocar el `repository`, la `table` o el `domain` directamente.
3. **`features-are-independent`** (backreference `$1`): una feature no puede importar los internos de otra; el único cruce permitido es el `public.ts` del proveedor, que reexporta tipos e interfaz de servicio. Todo otro import cross-feature rompe el build.
4. **`server-only-boundary`**: un componente cliente (`src/components`) no puede alcanzar el config de secretos, el pool de la base ni un `service`; el guardarraíl duro es el paquete `server-only` importado al tope de los módulos de servidor. Una cadena de imports cliente→servidor rompe el build.
5. **`no-circular`**: ningún ciclo de imports entre módulos; un grafo acíclico mantiene el slice navegable y descarta las dependencias mutuas que el layering hacia adentro ya prohíbe en intención.
6. **`egress-through-httpclient`**: ninguna primitiva de red cruda (`fetch` directo, `undici`, `axios`, `node:http`/`node:https`) se importa fuera de `src/core/http`. Toda llamada saliente atraviesa el puerto `HttpClient`; el egreso es un gate, no una recomendación.

El `.dependency-cruiser.cjs` exacto que codifica los seis contratos es la fuente única y vive en la [referencia de gates y tooling](./07_referencia-gates-tooling.md); aquí solo importa qué imponen y por qué.

dependency-cruiser corre los seis contratos como gate de CI y rompe el build si alguno se viola. Refuerzan el mismo borde dos gates más: `tsc --noEmit` (strict) y `pnpm run check`, que en local = CI corren los seis contratos.
