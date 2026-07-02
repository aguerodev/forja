---
id: arq.gates-tooling
titulo: Gates y tooling
tipo: referencia
tier: 2
audience: both
resumen: Configuraciones exactas de los gates (biome, dependency-cruiser, stryker, scripts, jobs de CI de verificación) y reglas de branch protection.
provides:
  - "biome.json"
  - "prettier-plugin-tailwindcss"
  - ".dependency-cruiser.cjs"
  - "stryker.conf.json"
  - "pnpm run check"
  - "pnpm run fix"
  - "scripts test:integration/test:mutation/test:contract"
  - "vitest --project unit vs integration"
  - "local = CI"
  - "smoke de contrato en PR (Schemathesis, 25 ejemplos; la pasada exhaustiva es dial)"
  - "OpenAPIRegistry / buildOpenApiDocument"
  - "protección de ramas según plan (free: convención + preflight de /forja:deploy como candado real; Team: branch protection como dial)"
  - "scaffold: estado real (generador de features pendiente, se copia la forma de un slice) y objetivo pnpm plop feature con flags condicionales"
  - "ci.yml jobs de verificación"
  - "engines + .nvmrc"
  - "gate de migraciones destructivas (linter con overrides, dentro de pnpm run check)"
  - "gate de registro OpenAPI (registerPath obligatorio + documento sin colisiones)"
  - "versionado de API /api/v1 + oasdiff (retrocompatibilidad de contrato como punto del dial)"
reads-before: [fund.stack, arq.convenciones, arq.testing]
related: [ops.pipeline-cicd, arq.crear-feature]
---

# Referencia de gates y tooling

Las herramientas que imponen las convenciones, sus configuraciones exactas y qué bloquea el merge. El porqué de que la convención viva en herramientas y no en prosa está en [Los principios del proyecto](../fundamentos/01_explicacion-principios.md#los-guardarraíles-que-importan-son-ejecutables).

## Versión de Node fijada

Toda la cadena —dev, CI, imagen— corre exactamente la misma versión de Node, declarada en dos lugares que se mantienen en sync:

- `package.json` con `engines` para que `pnpm install` falle si la versión local no coincide.
- `.nvmrc` para que `nvm use` (o el `corepack`/`fnm` equivalente) seleccione esa misma versión sin pensarlo.

```json
{
  "engines": { "node": ">=<NODE_MAJOR>.<NODE_MINOR> <NODE_MAJOR_SIGUIENTE>", "pnpm": ">=<PNPM_MAJOR>" },
  "packageManager": "pnpm@<PNPM_VERSION>"
}
```

```
# .nvmrc
<NODE_VERSION>
```

> Los marcadores `<NODE_VERSION>` / `<PNPM_VERSION>` representan la versión **actual** que el proyecto fija; lo invariante es el **patrón de pinning** (rango cerrado en `engines`, número exacto en `.nvmrc`, mismo número en el `Dockerfile`). Al iniciar un proyecto nuevo se reemplazan por la versión LTS de Node y la versión de pnpm vigentes.

El mismo número aparece en el `FROM node:<NODE_VERSION>-...` del `Dockerfile`. La versión es un dato único, no tres datos que pueden divergir.

## Biome (lint y formato)

Un solo binario para lint y formato: una herramienta por área. En `biome.json`:

```json
{
  "$schema": "https://biomejs.dev/schemas/1.9.4/schema.json",
  "files": {
    "ignore": ["claude_design/", "wiki/", "node_modules/", ".next/", ".obsidian/", ".claude/"]
  },
  "formatter": { "enabled": true, "indentStyle": "space", "indentWidth": 2 },
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true,
      "suspicious": { "noExplicitAny": "error" }
    }
  },
  "overrides": [
    {
      "include": ["tests/**", "e2e/**"],
      "linter": { "rules": { "suspicious": { "noExplicitAny": "off" } } }
    }
  ]
}
```

> **Caveat de seguridad.** El análisis estático de Biome (grupo `recommended`, que incluye reglas de la familia `suspicious`/seguridad) cubre un subconjunto del análisis posible; el grupo `security` explícito llega con Biome 2.x y queda como actualización pendiente. Por eso la seguridad se cubre en dos frentes complementarios: las reglas de Biome para el código y `pnpm audit` para el árbol de dependencias. Biome también bloquea los supresores sin justificar: un `@ts-expect-error` debe ser específico y razonado.

## Orden de clases Tailwind (`prettier-plugin-tailwindcss`)

Biome es dueño del formato de todo el código. La **única** excepción es el orden de las clases de Tailwind dentro de los `className`, que ordena `prettier-plugin-tailwindcss` de forma determinista. Prettier corre con **solo** ese plugin y con el mismo ancho e indentación que Biome, de modo que su único efecto neto es reordenar clases —no compite con el formateador.

```json
// .prettierrc.json
{
  "plugins": ["prettier-plugin-tailwindcss"],
  "printWidth": 80,
  "tabWidth": 2
}
```

Se ejecuta acotado a los archivos con marcado (`*.tsx`): `prettier --check` como gate en `check`, `prettier --write` en `fix`.

## dependency-cruiser (pureza arquitectónica)

Impone la arquitectura mediante **contratos ejecutables** como gate de CI que rompe el build: la pureza del dominio expresada como **allowlist**, el orden de capas dentro del slice (incluido el adaptador de egreso), la superficie pública entre features, el límite server-only del bundle, la **ausencia de ciclos** entre slices y la **canalización del egreso** por el cliente HTTP central. En `.dependency-cruiser.cjs`:

```js
// .dependency-cruiser.cjs
/** @type {import('dependency-cruiser').IConfiguration} */
module.exports = {
  forbidden: [
    {
      name: "domain-stays-pure",
      severity: "error",
      comment:
        "El núcleo del hexágono (domain.ts, ports.ts) solo puede importar su propio dominio, los errores de core y el código puro de shared. Todo lo demás —frameworks, ORM, driver, Zod, builtins de node y los adaptadores del slice, service.ts incluido— queda fuera por construcción.",
      from: { path: "(^|/)(domain|ports)\\.ts$" },
      to: {
        pathNot: [
          "(^|/)(domain|ports)\\.ts$",
          "^src/core/errors",
          "^src/shared/",
        ],
      },
    },
    {
      name: "inward-layering",
      severity: "error",
      comment:
        "Las dependencias apuntan siempre hacia adentro. El borde (route.ts, actions.ts) entra por el service y los schemas, nunca salta directo al repositorio, la tabla, el dominio ni a un adaptador de egreso. El repositorio es el adaptador de persistencia; cualquier integración con un tercero vive en un <provider>.adapter.ts del slice y queda igual de prohibida como destino directo del borde.",
      from: { path: "(^|/)(route|actions)\\.ts$" },
      to: { path: "(^|/)(repository|table|domain)\\.ts$|\\.adapter\\.ts$" },
    },
    {
      name: "features-are-independent",
      severity: "error",
      comment:
        "Una feature no puede alcanzar los internos de otra; el cruce va exclusivamente por su superficie pública public.ts.",
      from: { path: "^src/features/([^/]+)/.+" },
      to: {
        path: "^src/features/([^/]+)/.+",
        pathNot: "^src/features/$1/.+|^src/features/[^/]+/public\\.ts$",
      },
    },
    {
      name: "server-only-boundary",
      severity: "error",
      comment:
        "La capa de presentación (componentes cliente en src/components) no puede alcanzar el config de secretos (/run/secrets), el pool de la base ni un service. Adelanta —en el loop local, antes del bundler— el guardarraíl duro del paquete 'server-only'.",
      from: { path: "^src/components/" },
      to: { path: "^src/core/(config|db)/|(^|/)service\\.ts$" },
    },
    {
      name: "no-circular",
      severity: "error",
      comment:
        "El grafo de dependencias entre slices es acíclico. Aunque cada cruce cross-feature pase por public.ts (features-are-independent), eso no impide que A->public(B) y B->public(A) cierren un ciclo: a escala, los ciclos son el modo típico de podredumbre del monolito modular. Esta regla nativa de dependency-cruiser convierte 'el grafo no se enreda' de promesa en guardarraíl.",
      from: {},
      to: { circular: true },
    },
    {
      name: "egress-through-httpclient",
      severity: "error",
      comment:
        "Todo egreso de red sale por el cliente HTTP central de src/core/http (el puerto HttpClient y su único adaptador). Importar primitivas crudas de red —fetch global, undici, axios, node:http/node:https— desde cualquier otro lugar queda prohibido: ahí es donde viven el timeout requerido, el hook anti-SSRF y la redacción de secretos en telemetría. El seam de egreso deja de ser prosa y pasa a ser GATE.",
      from: { pathNot: "^src/core/http/" },
      to: {
        path: "^(undici|axios)$|^node:https?$",
      },
    },
  ],
  options: {
    tsPreCompilationDeps: true,
    tsConfig: { fileName: "tsconfig.json" },
    doNotFollow: { path: "node_modules" },
    enhancedResolveOptions: {
      exportsFields: ["exports"],
      conditionNames: ["import", "require", "node", "default"],
    },
  },
};
```

Cómo se leen los seis contratos:

- **`domain-stays-pure` es una allowlist, no una lista de prohibidos.** El `to.pathNot` enumera lo único permitido (el propio dominio, `core/errors`, `shared`); cualquier otro destino —un paquete npm, un builtin `node:*`, `service.ts`, un adaptador del slice— cae como violación por defecto. Así la regla no depende de recordar cada import impuro: lo que no está explícitamente permitido, rompe el build.
- **`inward-layering`** verifica el orden de capas dentro del slice: el borde no se saltea el service para tocar el repositorio, la tabla, el dominio **ni un adaptador de egreso** directamente. El regex cubre `repository.ts` (persistencia) y el sufijo `*.adapter.ts` (cualquier integración con un tercero: `<provider>.adapter.ts`), de modo que el SDK de un proveedor jamás entra por `route.ts`/`actions.ts` sin pasar por el service. La dirección hacia adentro queda comprobada, no recordada.
- **`features-are-independent`** usa el grupo de captura `$1`: la backreference exime los imports dentro de la propia feature y permite **un solo** punto de cruce hacia afuera, `public.ts`. La superficie pública (`src/features/<f>/public.ts`) reexporta tipos e interfaz de servicio; los internos quedan sellados. Única excepción declarada en la regla real: `table.ts` puede importar el `table.ts` de otra feature para definir FK constraints — es un concern de DDL, no acoplamiento de runtime.
- **`server-only-boundary`** prohíbe que un componente cliente alcance el config de secretos, el pool de la base o un service. El guardarraíl **duro** es el paquete [`server-only`](https://www.npmjs.com/package/server-only) importado al tope de `core/config.ts`, `core/db/client.ts`, `service.ts` y `repository.ts` (y `composition.ts` si el dial lo trajo): el bundler rompe el build ante cualquier cadena de imports cliente→servidor. Este contrato lo adelanta al loop local, antes de empaquetar.
- **`no-circular`** prohíbe ciclos en el grafo de imports. `features-are-independent` garantiza que el cruce pase por `public.ts`, pero no su dirección: dos slices que se importan mutuamente por su superficie pública compilan sin que ningún otro contrato lo note. La regla nativa `to: { circular: true }` cierra ese hueco —el grafo entre slices se mantiene acíclico— sin escribir un solo path a mano.
- **`egress-through-httpclient`** canaliza todo el egreso de red por `src/core/http`. El `from.pathNot` exime al propio hogar del cliente (donde vive el único adaptador autorizado a tocar el transporte); desde cualquier otro path, importar `undici`, `axios` o los builtins `node:http`/`node:https` rompe el build. Es el contrato que vuelve **GATE** el seam de egreso: el timeout requerido en la firma del puerto `HttpClient`, el hook anti-SSRF y la redacción de secretos en telemetría solo pueden vivir en un lugar si nadie puede abrir un socket crudo a su lado. (El `fetch` global no es un import resoluble, así que su prohibición fuera de `core/http` se cubre con una regla de lint complementaria; dependency-cruiser ataca los paquetes y builtins de red, que son el vector real de bypass.)

La configuración es completamente ejecutable: rompe el build si cualquiera de los seis contratos se viola.

## El comando único (`package.json`)

El dev y CI corren exactamente lo mismo —cero deriva— vía los scripts de `package.json`. `pnpm run check` es el bucle rápido que todo desarrollador (y todo agente) ejecuta en su loop:

```json
{
  "scripts": {
    "check": "biome check . && prettier --check \"**/*.tsx\" && tsc --noEmit && depcruise src && vitest run --project unit && pnpm check:migrations && pnpm audit --audit-level=high",
    "fix": "biome check --write . && prettier --write \"**/*.tsx\"",
    "test:integration": "vitest run --project integration",
    "test:mutation": "stryker run --incremental",
    "test:contract": "schemathesis run --experimental=openapi-3.1 --base-url http://localhost:3000 --hypothesis-max-examples 25 openapi.json",
    "check:migrations": "node scripts/lint-migrations.mjs src/core/db/migrations"
  }
}
```

Cada eslabón de `check` es un gate independiente; el primero que falla corta la cadena:

- `biome check .` — formato + lint.
- `prettier --check "**/*.tsx"` — orden determinista de clases Tailwind.
- `tsc --noEmit` — tipado `strict` como red de seguridad del lenguaje; nativo en el compilador, sin herramienta externa.
- `depcruise src` — los seis contratos de pureza arquitectónica.
- `vitest run --project unit` — la suite de dominio y casos de uso, sin I/O.
- `pnpm check:migrations` — el linter expand/contract de SQL (milisegundos; ver [el gate de migraciones](#el-gate-de-migraciones-destructivas)).
- `pnpm audit --audit-level=high` — auditoría del árbol de dependencias.

`pnpm run fix` aplica formato, autofixes y orden de clases en una pasada.

### Qué corre rápido y qué no (la promesa local=CI, sin trampa)

`pnpm run check` es deliberadamente **rápido**: es el bucle apretado que el TDD y la autocorrección del agente protegen. Por eso `check` corre **solo el proyecto `unit` de Vitest** (dominio + casos de uso, sin I/O, en milisegundos). Si arrancara Docker/Postgres en cada iteración, el bucle moriría.

Vitest define dos proyectos en su config:

- **`unit`** — `tests/**` de dominio y servicio, puro y determinista. Es lo que corre `check` y el loop rojo-verde local.
- **`integration`** — los tests que levantan un contenedor `testcontainers-node` a nivel de sesión para ejercer `repository.ts`/`table.ts` contra Postgres real.

Los gates **lentos** NO viven en `check` —correrlos ahí rompería el bucle y la promesa local=CI dejaría de ser honesta. Corren como pasos separados:

| Gate / job | Comando | Dónde corre |
| --- | --- | --- |
| Integración (testcontainers) | `pnpm test:integration` | Job aparte en cada PR, bloquea el merge (y a demanda local) |
| Mutation (Stryker) | `pnpm test:mutation` | Job **nightly** (ver [El job de mutation](#el-job-de-mutation-stryker-nightly-y-métrica)) |
| Contrato (Schemathesis) | `pnpm test:contract` | Smoke acotado (25 ejemplos) bloqueante en cada PR |

`pnpm run check` corre idéntico en tu máquina y en el job `check` de CI: eso es local=CI. Lo que CI suma por encima son los jobs de arriba: integración y el smoke de contrato bloquean el merge fuera del bucle rápido; mutation corre nightly (siguiente sección).

> **DIAL: pasada exhaustiva de Schemathesis.** Una corrida nightly sin el límite de 25 ejemplos es una escalación diferida, no parte de la base. **Disparador**: el primer bug de contrato que el smoke del PR no atrapó.

## El job de mutation (Stryker): nightly y métrica

El mutation score es una **métrica** informativa de calidad de test, no un gate de merge (la distinción [métrica vs gate](./04_explicacion-testing.md#métrica-vs-gate)): tanto la cobertura como el mutation score son métricas, y ninguna de las dos rompe el PR. El job corre **nightly**, fuera del gate de PR, reporta el score como señal de calidad y **no bloquea el merge**. Corre **incremental** (`--incremental`, reutilizando el estado de `reports/stryker-incremental.json`) acotado a los módulos de dominio y servicio tocados, contra el proyecto `unit` de Vitest. En `stryker.conf.json`:

```json
{
  "$schema": "./node_modules/@stryker-mutator/core/schema/stryker-schema.json",
  "testRunner": "vitest",
  "vitest": { "project": "unit" },
  "mutate": ["src/features/**/domain.ts", "src/features/**/service.ts"],
  "incremental": true,
  "thresholds": { "high": 100, "low": 100, "break": 100 }
}
```

- **`mutate`** acota el universo de mutantes a `domain.ts` y `service.ts` —la lógica que el dial declara intocable—; el transporte (route/actions) y los adaptadores no entran al reporte.
- **`thresholds.break: 100`** es el umbral del **reporte nightly**: cualquier mutante sobreviviente en lo tocado falla el job y deja la señal de calidad en rojo. Vive en `stryker.conf.json` como umbral del reporte, no como condición de integración.
- **`--incremental`** reutiliza el estado de la corrida anterior (`reports/stryker-incremental.json`) y muta solo lo que cambió desde entonces, para que el reporte sea proporcional al delta y no a todo el repo.

En CI es un job separado, **programado nightly** (no en `pull_request`):

```yaml
mutation:
  if: github.event_name == 'schedule' # nightly, no en cada PR
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: actions/cache@v4 # persiste el estado incremental entre corridas nightly
      with:
        path: reports/stryker-incremental.json
        key: stryker-incremental-${{ github.run_id }}
        restore-keys: stryker-incremental-
    - run: pnpm install --frozen-lockfile
    - run: pnpm test:mutation
```

> **La primera corrida de un repo greenfield.** Si todavía no hay `domain.ts`/`service.ts` con lógica, no hay mutantes que evaluar y el reporte pasa en vacío —correcto, no hay dominio que medir. La primera corrida con dominio real es completa y siembra `reports/stryker-incremental.json`; las siguientes mutan solo el delta.

> **Subir mutation a gate de merge: escalación del dial.** Cablear el `break: 100` como gate bloqueante de cada PR es un **punto del dial**, no el default. El disparador es un **dominio crítico o un equipo maduro** que lo justifique; mientras tanto, un proyecto típico de agencia no necesita esa ceremonia (robusto no es máximo): un mutante equivalente indecidible puede bloquear un PR sano sin aportar señal real. La promoción a gate se anota como escalación deliberada.

## El gate de migraciones destructivas

`drizzle-kit generate` diffea por **forma del esquema**: renombrar una columna en `table.ts` es indistinguible de borrar la vieja y crear una nueva, así que emite un `DROP COLUMN` + `ADD COLUMN` silencioso —pérdida total de datos de esa columna—. Dejar `expand/contract` como disciplina en prosa es exactamente el antipatrón que la doctrina combate en todo lo demás: un guardarraíl que se **recuerda**, no que se **ejecuta**. Por eso el SQL emitido entra a dos gates ejecutables.

**Linter de SQL expand/contract (rompe el build).** Un script propio (`scripts/lint-migrations.mjs`) parsea el SQL que `drizzle-kit generate` deja en `src/core/db/migrations/` y falla el PR ante dos clases de sentencia, cada una con su override:

- **Destructivas** (pierden datos): `DROP TABLE`, `DROP COLUMN`, `TRUNCATE`, `RENAME` → exigen `-- migration:allow-destructive <razón>` en la línea anterior.
- **Non-expand** (rompen el código viejo durante el rolling o toman locks bloqueantes): `SET NOT NULL`, `ALTER COLUMN ... TYPE`, `ADD COLUMN ... NOT NULL` sin `DEFAULT`, `CREATE UNIQUE INDEX` sin `CONCURRENTLY` → exigen `-- migration:allow-non-expand <razón>`.

La operación no queda prohibida —a veces es la correcta tras una ventana de `expand/contract`—; queda **bloqueada por defecto** y exige el override explícito y justificado al lado, con el mismo espíritu que un `@ts-expect-error` razonado:

```sql
-- migration:allow-destructive rename ya migrado en deploy previo (expand/contract paso contract)
ALTER TABLE "<tabla>" DROP COLUMN "<columna_vieja>";
```

```json
{
  "scripts": {
    "check:migrations": "node scripts/lint-migrations.mjs src/core/db/migrations"
  }
}
```

El override es rastreable en el diff —igual que un supresor de tipos— y obliga a nombrar la razón, no a esconderla.

El linter corre **dentro de `pnpm run check`** (es un paso más de la cadena), así que el gate es idéntico en local, en el preflight de `/forja:deploy` y en el job `check` del CI — no necesita un job propio: parsea texto en milisegundos.

Las migraciones se **aplican** de verdad contra un Postgres real (misma major que prod) en el job `contract` del CI, que migra la base antes de levantar la app y fuzzear el contrato. Aplicarlas contra una base **vacía** dos veces —en un job propio y en `contract`— era gasto duplicado sin señal nueva; se eliminó.

El how-to de `expand/contract` paso a paso (las recetas de `NOT NULL`, rename y split de tabla, más el backfill como runner batcheado y reanudable desacoplado del lock de `ALTER`) vive en [el how-to de migraciones](../operaciones/08_how-to-pipeline-cicd.md); este gate es lo que convierte esa disciplina en build roto cuando se la saltea.

> **DIAL: CI contra un snapshot prod-like, no contra base vacía.** Aplicar una migración sobre una base vacía siempre pasa: un `backfill`, un `NOT NULL` sin default sobre filas existentes o un `UNIQUE` con duplicados solo explotan contra **datos reales**. El job que restaura un snapshot representativo (fixture seedeado o dump anonimizado) y migra contra él es una **escalación del dial**, NO la base: es infraestructura con costo de mantenimiento sostenido —seedear/anonimizar el dump, mantenerlo representativo, restaurarlo en cada PR—. **Disparador**: la primera migración que muerde en producción por un fallo de la clase que solo aparece contra filas reales. Hasta entonces, el linter + la aplicación real en `contract` + el backup pre-migración validado del release son la cobertura proporcional al riesgo.

## Ensamblado del contrato OpenAPI

El contrato HTTP se **ensambla desde los slices**, no se redacta a mano. La API pública —Route Handlers (`route.ts`), webhooks, integraciones externas— es la única superficie que entra al contrato; cada `route.ts` registra sus operaciones en un **`OpenAPIRegistry` central** que vive en `src/core/http/openapi.ts`. Ese registro agrega todas las operaciones y sirve un documento **OpenAPI 3.1** único, que es el que Schemathesis fuzzea.

El registro central declara los componentes compartidos por todo el contrato. El más importante es el **cuerpo de error tipado `{ code, params?, message? }`**: forma parte del schema y describe las respuestas `4xx`/`5xx` estándar de cualquier operación. El `code` es el discriminante estable y **semántico** del `DomainError` (`conflict`, `not_found`, `upstream_unavailable`, `upstream_timeout`, `rate_limited`, `feature_disabled`, …); `params` lleva los datos estructurados para reconstruir el mensaje del lado del cliente; `message` es la glosa legible opcional. Así el contrato describe el camino feliz y los infelices con la misma forma.

El `code` **nunca hornea el número de status HTTP** —eso violaría las capas: el dominio no conoce HTTP—. La traducción `DomainErrorCode → status` (`conflict → 409`, `not_found → 404`, `upstream_unavailable → 502`, `upstream_timeout → 504`, `rate_limited → 429`, `feature_disabled → 503`, …) vive en `route.ts`, en el borde, que es la única capa que habla HTTP. El `code` queda semántico y estable en el dominio; el status es una decisión de transporte.

```ts
// src/core/http/openapi.ts
import {
  OpenAPIRegistry,
  OpenApiGeneratorV31,
} from "@asteasolutions/zod-to-openapi";
import { z } from "zod";

export const registry = new OpenAPIRegistry();

// El cuerpo de error tipado es parte del contrato: toda respuesta 4xx/5xx lo usa.
export const ErrorBody = registry.register(
  "ErrorBody",
  z.object({
    code: z.string(), // discriminante semántico del DomainError: 'conflict', 'not_found', 'upstream_timeout', …
    params: z.record(z.unknown()).optional(), // datos estructurados para reconstruir el mensaje en el cliente
    message: z.string().optional(), // glosa legible opcional
  }),
);

// Agrega todas las operaciones registradas por los route.ts y emite el documento OpenAPI 3.1.
export function buildOpenApiDocument() {
  const generator = new OpenApiGeneratorV31(registry.definitions);
  return generator.generateDocument({
    openapi: "3.1.0",
    info: { title: "API", version: "1.0.0" },
  });
}
```

Cada `route.ts` registra su operación —`method`, `path`, `request` y `responses`, incluyendo las respuestas `4xx`/`5xx` con `ErrorBody`— contra el registro central, usando los schemas Zod del propio slice:

```ts
// src/features/<feature>/route.ts
import { registry, ErrorBody } from "@/core/http/openapi";
import { EntitySchema, CreateEntitySchema } from "./schemas";

registry.registerPath({
  method: "post",
  path: "/api/<feature>",
  request: {
    body: {
      content: { "application/json": { schema: CreateEntitySchema } },
    },
  },
  responses: {
    201: {
      description: "Recurso creado",
      content: { "application/json": { schema: EntitySchema } },
    },
    409: {
      description: "Conflicto de versión (optimistic locking)",
      content: { "application/json": { schema: ErrorBody } },
    },
    422: {
      description: "Cuerpo inválido",
      content: { "application/json": { schema: ErrorBody } },
    },
  },
});

export async function POST(request: Request) {
  // valida con CreateEntitySchema, invoca la función del service,
  // y aquí —en el borde, no en el dominio— mapea DomainErrorCode → status HTTP
  // (conflict → 409, upstream_timeout → 504, rate_limited → 429, …) y emite { code, params?, message? }.
}
```

El documento ensamblado se sirve desde un Route Handler dedicado, y es exactamente el artefacto que el gate de contrato consume:

```ts
// src/app/api/openapi.json/route.ts
import { buildOpenApiDocument } from "@/core/http/openapi";

export function GET() {
  return Response.json(buildOpenApiDocument());
}
```

> **Las Server Actions internas NO entran al contrato.** `actions.ts` (`'use server'`) son RPC internas del front: las dispara un form o un evento de la propia app, devuelven estado serializable a la UI y no tienen una superficie HTTP pública estable que fuzzear. Por eso no se registran en el `OpenAPIRegistry` y quedan fuera del documento OpenAPI; su cobertura es por **tests de integración**, no por Schemathesis. El contrato describe únicamente lo que un tercero puede invocar: la API pública de los `route.ts`.

> **Versionado `/api/v1` — punto del dial, diferido.** El ensamblado deja lugar para prefijar las rutas bajo `/api/v1` y servir documentos por versión, pero **no se adopta todavía**: queda anotado como complejidad diferida en el dial, a activar cuando exista un consumidor externo que exija estabilidad versionada. Hasta entonces el contrato es uno solo, sin prefijo de versión.

## El gate de registro OpenAPI

El ensamblado desde los slices tiene dos modos de falla silenciosa que ningún tipo atrapa: un `route.ts` que **exporta un handler pero olvida `registerPath`** (el endpoint funciona, pero queda invisible para Schemathesis y para el contrato) y dos operaciones que **registran el mismo nombre de componente** en el `OpenAPIRegistry` (la segunda pisa a la primera y el documento sale corrupto). Ambas se convierten en fallo de build con dos gates baratos.

**`registerPath` obligatorio por handler de API pública.** Un test recorre cada `route.ts`, detecta los handlers HTTP exportados (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`) y exige que cada uno tenga su `registry.registerPath(...)` correspondiente. Un handler sin registro rompe el test —el mismo patrón de test negativo que protege la autorización—. El gate **excluye deliberadamente** `actions.ts` (las Server Actions internas no entran al contrato) y las rutas internas (`src/app/api/**` que no son superficie pública, como el propio `openapi.json/route.ts`): el glob acota a `src/features/**/route.ts`, no a "todo handler exportado del repo", para no disparar falsos positivos sobre lo que por diseño no se publica:

```ts
// tests/contract/register-path.test.ts
import { describe, it, expect } from "vitest";
import { collectExportedHandlers, collectRegisteredPaths } from "./_introspect";

const HTTP_METHODS = ["GET", "POST", "PUT", "PATCH", "DELETE"] as const;

describe("cada handler exportado se registra en el OpenAPIRegistry", () => {
  for (const handler of collectExportedHandlers("src/features/**/route.ts")) {
    it(`${handler.file} ${handler.method} tiene registerPath`, () => {
      const registered = collectRegisteredPaths(handler.file);
      expect(registered).toContainEqual({
        method: handler.method.toLowerCase(),
        path: handler.path,
      });
    });
  }
});
```

**`buildOpenApiDocument()` corre en CI y falla ante nombres duplicados.** El gate ensambla el documento real y verifica que no haya colisión de nombres de componente: `registry.register('Entity', ...)` desde dos slices distintos es un choque que hoy solo se ve en runtime o en el nightly. Ejecutarlo en el build lo adelanta:

```ts
// tests/contract/openapi-document.test.ts
import { describe, it, expect } from "vitest";
import { registry, buildOpenApiDocument } from "@/core/http/openapi";

describe("el documento OpenAPI ensambla sin colisiones", () => {
  it("no hay nombres de componente duplicados", () => {
    const names = registry.definitions
      .filter((d) => d.type === "schema" || d.type === "component")
      .map((d) => d.name ?? d.schema?._def?.openapi?.metadata?.refId);
    const duplicates = names.filter((n, i) => n && names.indexOf(n) !== i);
    expect(duplicates).toEqual([]);
  });

  it("buildOpenApiDocument() no lanza al generar", () => {
    expect(() => buildOpenApiDocument()).not.toThrow();
  });
});
```

> **Namespacing por feature como prevención.** El choque de nombres se vuelve improbable si cada componente se registra con prefijo de feature (`registry.register('<feature>.Entity', ...)`), prefijo que el generador de Plop puede inyectar al scaffoldear el `route.ts`. El gate sigue siendo la red dura; el namespacing reduce las veces que salta.

> **`oasdiff` — retrocompatibilidad como punto del dial.** Cuando exista un consumidor externo versionado, un gate de diff de contrato (`oasdiff`) compara el OpenAPI del PR contra el de la versión publicada y falla ante un cambio incompatible no intencional dentro de una versión. Es coherente con "el gate vive en el PR, no en la confianza": la retrocompatibilidad pasa de recordarse a verificarse. **No se adopta todavía** —el disparador es el primer partner con un contrato que mantener estable—; queda anotado en el dial junto al versionado `/api/v1`.

## Contract testing (Schemathesis)

Schemathesis ejerce el borde HTTP derivado del **documento OpenAPI 3.1 que ensambla el `OpenAPIRegistry` central** (`src/core/http/openapi.ts`) a partir de las operaciones que cada `route.ts` registra con sus schemas Zod. Corre en dos modos:

- **En cada PR (bloqueante):** un smoke acotado —presupuesto bajo de ejemplos (`--hypothesis-max-examples` chico)— contra la app levantada sobre una base efímera. Atrapa las roturas de contrato más obvias (status/shape divergente del OpenAPI) en el único camino a producción, sin alargar el PR.
- **Nightly (exhaustivo):** la pasada amplia con presupuesto generoso, que explora los caminos infelices donde Schemathesis más aporta.

```yaml
contract:
  needs: check
  if: github.event_name == 'pull_request'
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - run: pnpm install --frozen-lockfile
    - run: pnpm exec drizzle-kit migrate # base efímera de servicios CI
    - run: pnpm test:contract -- --hypothesis-max-examples 25
```

## Qué bloquea el merge y qué corre nightly

- **Bloquea el merge (cada PR), como jobs de CI:**
  - `pnpm run check` en verde (el bucle rápido: biome, prettier, tsc, depcruise con los seis contratos, vitest `unit` —que incluye los tests de `registerPath` y de documento OpenAPI sin colisiones—, el linter de migraciones, pnpm audit).
  - Job `integration` — la suite `integration` con testcontainers, contra la **misma major de Postgres que prod**.
  - Job `contract` — smoke de Schemathesis acotado (25 ejemplos) contra el OpenAPI generado; además aplica las migraciones contra Postgres real y ejecuta el **único `next build` pre-merge** del sistema.
  - El gate de seguridad del PR son las reglas de Biome (código) y `pnpm audit` (dependencias); el análisis estático de seguridad es deliberadamente acotado a esos dos frentes.
- **Programado / nightly (no bloquea el PR):**
  - Job `mutation` — `stryker run --incremental` con `break: 100` sobre el dominio/servicio tocado; sale temprano si no hay delta de dominio desde la última corrida (métrica de calidad de test, no gate: ver [El job de mutation](#el-job-de-mutation-stryker-nightly-y-métrica)).
  - Si el dial lo pide: la pasada exhaustiva de Schemathesis (disparador: el primer bug de contrato que el smoke no atrapó) y el análisis de supply chain de `Socket` por encima de `pnpm audit`.

Dos lecciones cableadas en `ci.yml` que la doctrina hereda: `pnpm/action-setup` va **sin** input de versión (lee `packageManager` de `package.json`; declararla dos veces rompe el setup), y el servicio Postgres del job `contract` **debe mapear el puerto** (`5432:5432`) porque `drizzle-kit` corre en el host del runner, no en un contenedor.

El cableado de estos jobs en el pipeline (concurrency, environment, orden de etapas de entrega) se documenta en [Pipeline de CI/CD](../operaciones/08_how-to-pipeline-cicd.md).

## Protección de ramas: qué es real según el plan de GitHub

Los gates de arriba solo valen si **no se pueden saltear** — y acá la doctrina es honesta sobre qué impone GitHub y qué no, porque depende del plan:

- **Con plan free y repo privado (el caso base de la agencia): GitHub NO ofrece branch protection ni rulesets.** Nada impide técnicamente un push directo a `main`. La regla "todo entra por PR" se sostiene por convención de equipo, y el **candado ejecutable real es el preflight del comando `/forja:deploy`**: nada llega a producción si no es `main`, limpio, al día con `origin/main` y con los gates verdes ([Release por comando](../operaciones/08_how-to-pipeline-cicd.md)). Un push directo furtivo a `main` sigue siendo posible, pero no despliega solo — y los jobs de CI en push a `main`/`develop` lo dejan en evidencia si rompe algo.
- **Con plan Team o repo público — escalación del dial** (disparador: más colaboradores externos o un cliente que exige el candado): activar branch protection en `main` con push directo prohibido, status checks requeridos (`check`, `integration`, `contract`; `mutation` queda fuera por ser nightly), rama actualizada antes del merge, y sin force-push ni borrado.

El principio no cambia: el gate vive en algo ejecutable, no en la confianza. Lo que cambia por plan es **dónde** vive ese ejecutable: en el preflight del deploy (free) o también en GitHub (Team).

## Scaffold: el estado real y el objetivo

**Estado real (honesto): el generador de features todavía NO existe.** El `plopfile.js` del proyecto de referencia tiene el generador `project` como stub y el de `feature` diferido. Mientras tanto, una feature nueva nace **copiando la forma de un slice existente** del proyecto de referencia (los nombres de archivo fijos por capa: `domain.ts`, `ports.ts`, `use-cases.ts`, `service.ts`, `schemas.ts`, `repository.ts`, `route.ts`, `actions.ts`, `public.ts`, y `table.ts` solo si persiste) y su espejo en `tests/unit/features/<feature>/` + `tests/integration/features/<feature>/`. La receta paso a paso vive en [Crear una feature](./08_how-to-crear-feature.md). Los agentes de IA siguen esa receta con fidelidad — por eso el hueco duele menos de lo que la doctrina "convención en herramienta, no en prosa" predice; pero sigue siendo un hueco declarado, no una herramienta.

**Objetivo (deuda declarada de la plantilla): `pnpm plop feature <feature>`.** Cuando se implemente, el generador debe emitir el slice con emisión **condicional** por flags —`--persisted` (agrega `table.ts` + `repository.ts` + espejo de integración), `--with-domain` (agrega `domain.ts` solo si hay invariantes), `--provider <p>` (agrega el adaptador de egreso y su espejo)— para respetar la regla del mínimo en vez de crear todo y hacer borrar. Y no se detiene en el slice: genera los bindings de `src/app/` (la `page.tsx` que valida `searchParams` y el `route.ts` reexportador) y el esqueleto de `registerPath` con las respuestas `ErrorBody`, para que el endpoint entre al contrato OpenAPI desde el primer commit.

**El template de proyecto** es hoy el propio repositorio de referencia: se clona la estructura (configs de Biome/dependency-cruiser/Stryker, `.prettierrc.json`, `tsconfig.json` strict con paths `@/*`, `.nvmrc`, scripts de gates, `Dockerfile` multi-stage, `stack.yml`, `deploy.sh`, `ci.yml` de gates, `AGENTS.md`/`CLAUDE.md` y la `wiki/`) siguiendo [Arrancar un proyecto nuevo](../proceso/04_how-to-arrancar-proyecto-nuevo.md).
