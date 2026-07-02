---
id: arq.estilos-frontend
titulo: Estilos de frontend
tipo: explicacion
tier: 2
audience: both
resumen: Modelo server-first (RSC por defecto), el sistema de tokens en dos capas, composición con cva/cn/shadcn, accesibilidad y dark mode.
provides:
  - React Server Components por defecto ('use client' como excepción en hojas)
  - setup de Tailwind v4 (@tailwindcss/postcss, @import "tailwindcss", sin tailwind.config.js)
  - tokens en dos capas (primitivas privadas --tk-* + @theme inline)
  - dark mode como override de ~5 primitivas --tk-* (prefers-color-scheme vs cookie-in-layout)
  - prefers-reduced-motion (bloque global)
  - accesibilidad (WCAG 2.2 AA baseline, --tk-ring, contraste OKLCH verificado en CI, vitest-axe, @axe-core/playwright)
  - cn() (clsx + twMerge) y cva() / class-variance-authority
  - "@apply prohibido en componentes"
  - shadcn/ui copy-in, Radix primitivas, registry shadcn privado
  - "paquete de tokens compartido multi-proyecto — entrada del dial"
  - interactividad progresiva / islas cliente en el layout
  - render dinámico (dynamic = force-dynamic), cache() de React, archivos de segmento (loading/error/not-found), streaming por Suspense vs SSE (dial)
  - límite Server -> Client (props serializables)
  - FOUC (flash of unstyled/wrong-theme content)
  - over-engineering fuera del dial (tailwind.config.js, autoprefixer, tailwind-variants, Style Dictionary, next-themes, Turborepo/Nx)
  - "patrón de dashboard server-first (tabla + widgets + islas hoja bajo Suspense; URL como fuente de verdad del filtro)"
  - "librería de charting como escalación (componente chart de shadcn/ui con Recharts; data-viz, única dependencia de cliente pesada)"
reads-before: [arq.hexagonal]
related: [fund.stack, arq.crear-feature]
---

# El frontend por dentro: por qué la UI es server-side y cómo se estiliza con poco código

Por qué la interfaz se renderiza en el servidor por defecto, por qué los estilos se resuelven con Tailwind v4 sin ceremonia de configuración, y cómo se gestionan CSS, componentes e interactividad con la menor cantidad de código posible. El modelo base: **UI server-side por defecto (React Server Components), interactividad en las hojas, sin SPA como punto de partida**.

## Por qué Server Components por defecto

En el App Router de Next.js, **cada componente es un Server Component salvo que se marque lo contrario**. El servidor rinde el árbol a HTML, lo envía ya armado, y el cliente solo hidrata las islas interactivas. La UI nace como **HTML que el servidor ya rindió**, sin estado de cliente, sin un bundle de lógica de negocio que versionar, sin una capa de datos duplicada en el navegador.

La decisión va junto a la forma del backend: igual que el [monolito modular](./01_explicacion-arquitectura-hexagonal.md) entrega el sistema como un espacio navegable, la UI se rinde en el mismo proceso que ya tiene acceso al dominio. Un Server Component **lee** llamando al service del dominio directamente —la función que la fachada `service.ts` del slice exporta ya cableada— dentro de su cuerpo `async`, sin saltar la red dos veces; las **mutaciones** se delegan a los `actions.ts`. La interactividad es la **excepción**: `'use client'` se reserva para las hojas del árbol que de verdad necesitan estado, eventos o APIs del navegador. Marcar un componente como cliente es una decisión consciente sobre **una hoja concreta**, no sobre la página entera.

Tailwind opera igual en ambos mundos: es **extracción estática en build**, no runtime. Las clases se resuelven al compilar, así que un Server Component y un Client Component reciben exactamente el mismo CSS sin coste adicional ni configuración distinta. El render server-side y la estrategia de estilos se ignoran mutuamente, que es justo lo que se quiere.

## Cómo se gestiona el CSS

El setup es **mínimo a propósito**. Tres dependencias (`tailwindcss`, `@tailwindcss/postcss`, `postcss`) y un `postcss.config.mjs` de tres líneas. No hay `tailwind.config.js`, ni `content` array, ni `autoprefixer`:

```js
// postcss.config.mjs
const config = {
  plugins: { "@tailwindcss/postcss": {} },
};
export default config;
```

Tailwind se importa **una sola vez** en `globals.css`, que el `layout.tsx` raíz carga para toda la app:

```css
/* src/app/globals.css */
@import "tailwindcss";
```

Sin pipeline propio, sin minificador, sin watcher: el build de Next.js ya hace la extracción y el tree-shaking del CSS no usado. El navegador recibe solo las utilidades que el árbol realmente referencia.

### Tokens en dos capas (el corazón)

El sistema de diseño vive en **dos capas**, y esa separación es la pieza clave.

**Capa 1 — primitivas privadas `--tk-*`.** Los valores crudos (colores, radios, espaciado, tipografía) se declaran como *custom properties* en `@layer base :root`. Son la **única fuente de verdad** del valor y nunca se usan directamente en el markup:

```css
/* src/app/globals.css */
@layer base {
  :root {
    --tk-color-bg: oklch(0.99 0 0);
    --tk-color-fg: oklch(0.2 0.02 270);
    --tk-color-primary: oklch(0.55 0.18 250);
    --tk-color-primary-fg: oklch(0.98 0 0);
    --tk-color-ring: oklch(0.55 0.18 250);
    --tk-radius: 0.5rem;
  }
}
```

`--tk-color-ring` no es decorativo: es el **token del anillo de foco** y es parte del [contrato de accesibilidad](#contrato-de-accesibilidad). Toda variante interactiva lo consume vía `focus-visible:ring-ring`, de modo que el indicador de foco es una primitiva del sistema, no un detalle que cada componente reinventa.

**Capa 2 — mapeo a utilities con `@theme inline`.** Las primitivas se exponen como utilidades de Tailwind a través de `@theme inline` y `var()`. Esto genera clases como `bg-background`, `text-foreground`, `bg-primary`, `rounded-lg`, manteniendo las primitivas privadas detrás:

```css
@theme inline {
  --color-background: var(--tk-color-bg);
  --color-foreground: var(--tk-color-fg);
  --color-primary: var(--tk-color-primary);
  --color-primary-foreground: var(--tk-color-primary-fg);
  --color-ring: var(--tk-color-ring);
  --radius-lg: var(--tk-radius);
}
```

El payoff es directo: **cambiar la marca o activar dark mode es sobrescribir ~5 variables `--tk-*`**, sin tocar utilidades, sin build extra, sin runtime. El dark mode es un override de las mismas primitivas bajo un selector:

```css
@layer base {
  .dark {
    --tk-color-bg: oklch(0.18 0.02 270);
    --tk-color-fg: oklch(0.95 0 0);
  }
}
```

La **identidad** vive en una capa de tokens propia, no dispersa en literales repartidos por la hoja.

Un bloque global respeta las preferencias de movimiento del usuario, exigido por WCAG 2.2 y relevante para quien tiene trastornos vestibulares. Vive una sola vez en `globals.css` y cubre transiciones y animaciones de todo el árbol (incluidas las que introducen las primitivas de Radix):

```css
/* src/app/globals.css */
@media (prefers-reduced-motion: reduce) {
  *,
  ::before,
  ::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
  }
}
```

## Composición: solo dos helpers

Toda la composición de clases pasa por **dos herramientas y ninguna más**. Más helpers significa más formas de hacer lo mismo, que es exactamente lo que erosiona la consistencia.

**`cn()` para overrides ad-hoc.** Un único helper en `lib/utils.ts` que combina `clsx` (clases condicionales) con `twMerge` (resuelve conflictos de Tailwind, gana la última). Se usa cuando un consumidor necesita pisar una clase puntual:

```ts
// src/lib/utils.ts
import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}
```

**`cva` para variantes.** Toda la lógica de variantes vive en `cva()`, **nunca en ternarios dentro del JSX**. El componente declara sus variantes una vez y el JSX queda limpio:

```ts
// src/components/ui/button.tsx
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const buttonVariants = cva(
  "inline-flex items-center justify-center rounded-lg text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 motion-reduce:transition-none disabled:opacity-50",
  {
    variants: {
      variant: {
        primary: "bg-primary text-primary-foreground hover:opacity-90",
        ghost: "bg-transparent hover:bg-foreground/5",
      },
      size: {
        sm: "h-8 px-3",
        md: "h-10 px-4",
      },
    },
    defaultVariants: { variant: "primary", size: "md" },
  },
);

type ButtonProps = React.ComponentProps<"button"> &
  VariantProps<typeof buttonVariants>;

export function Button({ className, variant, size, ...props }: ButtonProps) {
  return (
    <button className={cn(buttonVariants({ variant, size }), className)} {...props} />
  );
}
```

`@apply` queda **prohibido en componentes**: la composición se expresa en `cva` y `cn`, no extrayendo clases a CSS. `@apply` solo se tolera para CSS de terceros o estilos de prosa (`prose`), donde no hay JSX que componga.

## Componentes: shadcn/ui copy-in

Los componentes de UI se traen con **shadcn/ui**: no es una dependencia que se instala, es código que se **copia dentro del repo**. Debajo usa primitivas accesibles de Radix (foco, teclado, ARIA resueltos), pero el código vive en `src/components/ui/` y **cada repo es dueño de sus componentes**. Se editan como código propio, encajan con los tokens de dos capas (usan las utilidades `bg-primary`, `rounded-lg`, …) y no introducen una caja negra que actualizar a ciegas.

El ordenado de clases lo resuelven dos herramientas en cadena: `prettier-plugin-tailwindcss` (single-purpose) corre **primero** y ordena las clases por convención; [Biome](../fundamentos/03_referencia-stack-desarrollo.md) corre **último** y hace el resto del formato. Cuando el sorter de clases de Biome salga de su fase nursery, esta cadena se colapsa a Biome-only —una herramienta menos, fiel a "una herramienta por área".

## Interactividad progresiva

La página funciona renderizada en el servidor; la interactividad se suma **en la hoja que la necesita**, marcándola con `'use client'`. El caso típico —copiar un enlace al portapapeles— es un componente cliente pequeño que usa `navigator.clipboard` con su *fallback*, sin arrastrar el resto de la página al cliente:

```tsx
// src/components/copy-button.tsx
"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";

export function CopyButton({ value }: { value: string }) {
  const [copied, setCopied] = useState(false);
  async function copy() {
    await navigator.clipboard.writeText(value);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }
  return (
    <Button variant="ghost" size="sm" onClick={copy}>
      {copied ? "Copiado" : "Copiar"}
    </Button>
  );
}
```

La URL a copiar se construye en cliente con `window.location.origin`, de modo que el Server Component que la rinde **no necesita conocer el dominio** (evita acoplamiento). El límite cliente/servidor queda en una hoja, y todo lo de arriba sigue siendo HTML que el servidor ya rindió.

## El modelo de render: dinámico por defecto y revalidación tras mutar

Renderizar en el servidor abre una pregunta: **¿cuándo se vuelve a ejecutar ese render?** El App Router cachea el resultado de una ruta de forma agresiva, y una página que lee datos sin marcarse dinámica puede congelarse en el build y servir datos rancios. Como las páginas de este stack leen su estado de Postgres, la norma es explícita:

**Una página que lee datos del dominio es dinámica.** Se rinde por request, no se congela en build. Esa lectura la hace el cuerpo `async` de la `page.tsx` llamando al **service del dominio directamente**: la página invoca la función que `service.ts` exporta ya cableada. No hay Server Actions de por medio —son territorio de mutación— ni una capa de queries intermedia; el service del dominio alcanza:

```tsx
// src/app/<feature>/page.tsx
import { list<Feature> } from "@/features/<feature>/service";

export const dynamic = "force-dynamic";

export default async function Page() {
  const items = await list<Feature>();
  return (
    <main>
      <h1><Feature></h1>
      <FeatureList items={items} />
    </main>
  );
}
```

El export `dynamic` declara el **modo de render**: la ruta se rinde por request y no se congela en build. En la práctica, leer cookies o headers dentro del render ya fuerza ese modo; el export lo deja **explícito y auditable** en vez de depender de un efecto colateral. Render server-side y dominio comparten proceso, así que la lectura es una llamada a función dentro del mismo request: `service.ts` entrega el caso de uso ya cableado, los use cases aplican las reglas, y el Server Component rinde el resultado a HTML. Las **Server Actions quedan reservadas a la mutación** disparada desde forms o islas cliente; la lectura nunca pasa por ellas.

**Toda mutación termina invalidando lo que cambió.** Una Server Action que escribe en la base no refresca la UI por sí sola: el cache de ruta seguiría sirviendo el render anterior. Por eso toda action de mutación cierra con `revalidatePath` o `revalidateTag` del recurso afectado, dentro del `actions.ts` del slice:

```ts
// src/features/<feature>/actions.ts
"use server";
import { revalidatePath } from "next/cache";

export async function updateItem(/* ... */) {
  // ... mutación a través del dominio
  revalidatePath("/<feature>");
}
```

Esto es un **guardarraíl ejecutable**, no una recomendación: que cada action de mutación llame a `revalidate*` es lintable, igual que la pureza del dominio que impone [dependency-cruiser](./02_referencia-estructura-repo.md).

**`cache()` de React deduplica lecturas dentro de un mismo render.** Si dos componentes del árbol necesitan el mismo dato en una request, envolver la lectura en `cache()` garantiza **una sola** ida a la base en ese render, sin un cache global ni TTL que invalidar:

```ts
import { cache } from "react";

export const getItem = cache(async (id: string) => {
  // se ejecuta una vez por render, aunque se llame N veces
});
```

Es deduplicación por request —memoria de un solo render—, distinta del cache de ruta que se invalida con `revalidate*`.

## La frontera de lectura: `searchParams` validados antes del service

El camino de lectura tiene su propia frontera de validación, igual que la mutación (en `actions.ts`) y la API externa (en `route.ts`). Una página con filtros, paginación u orden recibe esos parámetros como **`searchParams` crudos**: un `Record<string, string | string[] | undefined>` sin tipar, que llega de la URL y puede traer cualquier cosa. Pasarlos directo al service rompería la regla que protege a los otros bordes: **datos ya validados llegan al service, nunca input crudo**.

La frontera es un **schema Zod** —`searchParamsSchema`, que vive en el `schemas.ts` del slice— que la `page.tsx` **invoca** (no define) **antes** de llamar al service: coacciona los strings de la URL a tipos del dominio, aplica defaults acotados y rechaza lo inválido. El contrato normativo —la firma `list({ filters, page, pageSize, sort }) -> { rows, total? }`, la allowlist de columnas ordenables, el `.max()` de `pageSize`, offset vs cursor y el matiz de `rows`/`total` como snapshots no atómicos— vive en las [convenciones](./03_referencia-convenciones-codigo.md); el ejemplo ejecutable de schema, page y service, en [Crear una feature](./08_how-to-crear-feature.md). Para esta página basta retener que el service nunca ve un string sin validar, que no hay una capa de queries intermedia, y que `total` es opcional: la tabla solo pinta el conteo si llega.

## Los archivos especiales del segmento: loading, error, not-found

El render asíncrono del App Router tiene convenciones de archivo propias —la pieza que `convención sobre configuración` aporta para async, error y streaming. Cada una vive **junto a la `page.tsx`** del segmento y el framework las cablea sin registro manual:

- **`loading.tsx`** — el fallback de Suspense a nivel de ruta. Mientras el Server Component `await`-ea sus datos, el servidor ya envía este esqueleto; el contenido llega cuando está listo.
- **`error.tsx`** — el error boundary del segmento. Captura lo que se lance sin manejar dentro de su subárbol y rinde una UI de recuperación. Es un Client Component (`'use client'`) porque necesita un botón de reintento.
- **`not-found.tsx`** — la respuesta a `notFound()`, para el recurso que no existe.

Plop scaffoldea `loading.tsx` + `error.tsx` junto a cada `page.tsx` que lea datos, de modo que ningún segmento con I/O quede sin su esqueleto ni sin su boundary.

**El streaming de HTML por Suspense es default, no dial.** Aislar una parte lenta del árbol bajo `<Suspense>` hace que el resto de la página se envíe de inmediato y el fragmento lento llegue en streaming cuando resuelve. Eso es **gratis** en el modelo de render —no hay infraestructura que sumar, no es un punto del dial—:

```tsx
// src/app/<feature>/page.tsx
import { Suspense } from "react";

export default function Page() {
  return (
    <main>
      <h1><Feature></h1>
      <Suspense fallback={<FeatureSkeleton />}>
        <FeatureList /> {/* await a la DB aislado: no bloquea el TTFB */}
      </Suspense>
    </main>
  );
}
```

Distinto del **streaming de datos en vivo** (SSE, WebSockets), que empuja actualizaciones del servidor al cliente después del primer render y **sí** es un punto del [dial](../fundamentos/01_explicacion-principios.md): suma una conexión persistente y un canal de transporte que el setup base no tiene. El streaming de HTML por Suspense divide *un* render; el streaming en vivo abre *un canal continuo*. Confundirlos lleva a tratar como costoso algo que es default, o como gratis algo que no lo es.

## El patrón de dashboard: tabla, widgets e islas hoja

Un dashboard es donde todas las piezas anteriores se ensamblan y donde el modelo server-first se pone a prueba: filtros en la URL, una tabla paginada, varios widgets de agregación y un gráfico. La tentación es marcar la página entera como `'use client'` y resolverlo en el navegador. **El patrón correcto es el opuesto**: la `page.tsx` es un Server Component que rinde la estructura, y el cliente aparece solo en **las hojas que de verdad lo necesitan**.

La página valida sus `searchParams` con el schema Zod, lee del service server-side y rinde tabla y widgets. Cada widget que cuelga de una query potencialmente lenta vive **bajo su propio `<Suspense>`**, de modo que el esqueleto de la página y los widgets rápidos llegan de inmediato y la agregación pesada streamea cuando resuelve —**una query lenta no bloquea el TTFB del resto**:

```tsx
// src/app/<feature>/dashboard/page.tsx
import { Suspense } from "react";
import { searchParamsSchema } from "@/features/<feature>/schemas";
import { FilterBar } from "./filter-bar";       // isla: empuja filtros a la URL
import { Pagination } from "./pagination";       // isla: control de paginación
import { RevenueChart } from "./revenue-chart";  // isla: canvas del gráfico
import { FeatureTable, KpiCards } from "./widgets"; // server, rinden HTML

export const dynamic = "force-dynamic";

export default async function DashboardPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const query = searchParamsSchema.parse(await searchParams);
  return (
    <main>
      <FilterBar /> {/* lee/escribe searchParams en el cliente */}
      <Suspense fallback={<KpiSkeleton />}>
        <KpiCards query={query} /> {/* await aislado: agregación rápida */}
      </Suspense>
      <Suspense fallback={<ChartSkeleton />}>
        <RevenueChartWidget query={query} /> {/* serie lenta, no bloquea el resto */}
      </Suspense>
      <Suspense fallback={<TableSkeleton />}>
        <FeatureTable query={query} />
      </Suspense>
      <Pagination /> {/* preserva filtros al cambiar de página */}
    </main>
  );
}
```

Las **islas hoja** son concretas y pequeñas, cada una con una sola responsabilidad de cliente:

- **`FilterBar`** — empuja el estado del filtro a la URL (`useRouter` + `useSearchParams`), de modo que el filtro es estado de servidor: cambiarlo navega y la `page.tsx` re-rinde con los nuevos `searchParams` ya validados. La **URL es la fuente de verdad** del filtro, no un `useState` que se desincroniza.
- **`Pagination`** — el control de página, que reescribe `page` en la URL preservando el resto de los params.
- **`RevenueChart`** — el **canvas del gráfico**, la única isla con una dependencia de cliente pesada e ineludible (SVG/canvas, tooltips, hover).

El widget de servidor `RevenueChartWidget` hace el `await` a la agregación y **computa la serie en el servidor**; el dato cruza el borde Server→Client como **prop serializable** (un array de `{ label, value }`), y la isla `RevenueChart` solo lo pinta. Respeta la regla del límite: cruza el **dato**, no comportamiento ni un objeto del dominio. El [cuarto contrato de dependency-cruiser](./02_referencia-estructura-repo.md) (frontera server-only) garantiza que ninguna de estas islas pueda alcanzar un `service.ts`, `core/db` o `core/config`: el dashboard **no degenera en un árbol todo-cliente**, y el guardarraíl que lo impide es ejecutable, no aspiracional.

**Herramienta de charting por defecto.** El gráfico se rinde con el componente `chart` de [shadcn/ui](#componentes-shadcnui-copy-in) —copiado al repo como el resto, con **Recharts** debajo—, consistente con `una herramienta por área` y el modelo copy-in. Su costo: una librería de gráficos es la **única dependencia de cliente pesada** que el setup mínimo no trae, así que sumarla es una **escalación consciente**, no un default que todo proyecto arrastra. Disparador: **el producto necesita data-viz de verdad** (un dashboard con series temporales o distribuciones). Hasta entonces, KPIs y tablas se rinden con HTML server-side y CSS, sin tocar el bundle del cliente. La frontera no se mueve: el **dato siempre se computa en el servidor** y cruza como prop serializable; la isla solo dibuja.

## El límite Server→Client

`'use client'` no es un interruptor de página: marca el **borde** donde el árbol pasa de HTML rindido en servidor a JavaScript hidratado en el navegador. Ese borde tiene reglas duras.

**Las props que cruzan a un Client Component deben ser serializables.** Lo que el servidor pasa a una isla cliente viaja serializado: valores planos (strings, números, booleans, arrays y objetos de esos), `null`. **No** cruzan funciones, instancias de clase, ni objetos del dominio con métodos. Un `Date` cruza pero conviene pasar el dato ya formateado o como ISO string para no depender de la zona horaria del cliente. Si se necesita pasar comportamiento, se pasa el **dato** y la isla decide qué hacer con él.

**Los módulos de servidor se marcan `server-only`.** Una cadena de imports que arranca en un Client Component no debe alcanzar nunca código de servidor —`core/config.ts` que lee `/run/secrets`, `core/db/client.ts` con el pool de Postgres, el `service.ts`, el `repository.ts` o el `composition.ts` de un slice—. Para que ese cruce **rompa el build en vez de filtrar secretos al bundle**, esos módulos importan `server-only` en su primera línea:

```ts
// src/features/<feature>/service.ts
import "server-only";
```

Un contrato de [dependency-cruiser](./02_referencia-estructura-repo.md) refuerza el borde: ningún módulo `'use client'` puede alcanzar `core/db`, `core/config` ni un `*/service.ts`. Guardarraíl barato que cierra un agujero de seguridad real, no solo una convención de estilo.

**Los providers de contexto son islas cliente en el layout.** Un contexto de React (tema, por ejemplo) necesita estado de cliente, así que su provider es un Client Component. Se coloca **como isla en el `layout.tsx`**, envolviendo `{children}`: el provider hidrata, pero los children que recibe siguen siendo Server Components rindidos en servidor. El estado de cliente queda contenido en la frontera del provider, sin arrastrar el árbol al bundle.

## Contrato de accesibilidad

Las primitivas de Radix que trae shadcn/ui resuelven el **comportamiento** de un componente —foco-trap de un `Dialog`, roving tabindex de un `Menu`—, pero la accesibilidad es una propiedad del **sistema** que se rompe en la composición. El stack fija un piso verificable: **WCAG 2.2 AA** como línea base innegociable, con un checklist por slice y gates ejecutables.

**Foco visible.** Toda variante interactiva incluye `focus-visible:ring-2 focus-visible:ring-ring` (ya en el base del `cva` del Button). El anillo usa el token `--tk-ring`, así que el indicador de foco es consistente en todo el sistema y cubre los criterios 2.4.11 y 2.4.13 de WCAG 2.2.

**Contraste de los tokens OKLCH, verificado en CI.** Las primitivas son `oklch(...)` con luminosidad `L` explícita, y rebrandear sobrescribiendo ~5 primitivas es justo el punto donde el contraste se rompe en silencio, por proyecto. Un par como `--tk-color-primary` sobre `--tk-color-primary-fg` blanco puede caer en zona borderline de 4.5:1 y **hay que verificarlo**. El gate: un test que parsea los pares semánticos (`fg/bg`, `primary/primary-fg`, `ring/bg`, y los de estado) en light **y** en `.dark` y falla si un par cae por debajo de AA (4.5:1 texto normal, 3:1 texto grande). Vive en `pnpm run check` y, con el paquete de tokens compartido, viaja a cada repo: el override de marca **debe** pasar el gate en ambos temas.

**Navegación por teclado y ARIA en la composición.** Radix da el comportamiento de cada primitiva; el slice es responsable de lo que Radix no ve: jerarquía de headings, landmarks, orden de tabulación coherente, `label` asociado a cada control, y nada operable solo con mouse.

**Errores de formulario accesibles.** Una Server Action de mutación valida con sus schemas Zod y devuelve un resultado **serializable** del tipo `{ ok: true, data } | { ok: false, fieldErrors, formError }`, consumido en la isla cliente con `useActionState`. La capa de accesibilidad sobre ese estado es convención de slice:

- cada campo cablea `aria-invalid` y `aria-describedby` apuntando al id de su mensaje de error;
- un resumen de errores con `role="alert"` y `tabindex={-1}` recibe **foco** tras un submit fallido, para que el usuario de lector de pantalla sepa qué pasó sin cazar el error visualmente.

Cuándo una action **devuelve** estado de error (validación, conflicto de negocio → se pinta junto al campo) y cuándo **lanza** (fallo inesperado → lo captura `error.tsx`) es parte del mismo contrato.

**Testing de a11y en el gate.** Coherente con `guardarraíles ejecutables`: `vitest-axe` sobre los componentes de `src/components/ui/` y un smoke de `@axe-core/playwright` en los flujos E2E que ya existen. axe es el estándar de facto —`una herramienta por área`— y este check de a11y de bajísimo costo evita que las regresiones se publiquen en silencio.

## Dark mode: la clase correcta en el primer paint

El dark mode es un override de primitivas bajo un selector (`.dark { --tk-* }`), pero **dónde** se decide ese selector tiene una trampa: con RSC y sin estado de cliente, el servidor no conoce la preferencia del usuario en el primer render. Si la clase `.dark` la pone JavaScript tras hidratar, el usuario ve un **flash del tema equivocado** (FOUC). Dos estrategias evitan el flash, según haga falta toggle manual o no:

- **Solo `prefers-color-scheme`** (cero runtime, cero FOUC, sin toggle manual). Los overrides `--tk-*` se aplican bajo `@media (prefers-color-scheme: dark)` en vez de bajo `.dark`. El servidor no necesita saber nada: el navegador resuelve el tema con el sistema operativo. Es el default cuando el producto no pide elegir tema a mano.
- **Toggle manual con cookie leída en el layout server-side.** La preferencia se persiste en una **cookie** (no en `localStorage`, que el servidor no ve), el `layout.tsx` la lee y rinde la clase `.dark` directamente en `<html>`. El servidor ya emite el HTML con el tema correcto: no hay flash y no hace falta un script bloqueante en `<head>`. El costo a tener presente: leer la cookie **opta la ruta a render dinámico** (consistente con la norma de `dynamic` de la sección de render), así que el toggle de tema y el modelo de caché se deciden juntos, no por separado.

`next-themes` resuelve esto con un script inline bloqueante; sigue siendo una opción de runtime para el **toggle de usuario**, pero la cookie-en-el-layout encaja mejor con `UI server-side` porque mantiene la decisión del tema del lado del servidor. En cualquier caso, la clase de tema vive en `<html>`, una sola vez, no esparcida por el árbol.

## El dial: over-engineering a evitar

Estas decisiones son un punto del dial, no un techo. El dial también marca lo que **no** se sube sin una razón concreta, porque cada una de estas piezas reintroduce ceremonia que el setup mínimo eliminó a propósito:

- **`tailwind.config.js` y el `content` array.** La configuración vive en CSS (`@theme inline`, `@source`); volver a un archivo JS de config es ceremonia sin pago.
- **`autoprefixer`.** Los targets modernos no lo necesitan; suma un plugin a la cadena PostCSS para nada.
- **`tailwind-variants` encima de `cva`.** Una capa de abstracción sobre la que ya resuelve las variantes. Dos formas de hacer lo mismo erosionan la consistencia.
- **Naming de tokens de tres niveles.** Dos capas (`--tk-*` privadas → utilities) cubren marca y dark mode. Un tercer nivel es indirección que nadie lee.
- **`@apply` en componentes.** La composición es `cva` + `cn`; extraer clases a CSS esconde la lógica de variantes fuera del componente.
- **Monorepo (Turborepo/Nx).** El paquete npm de tokens ya comparte la fuente de verdad entre polyrepos sin acoplar builds ni despliegues.
- **Style Dictionary.** Generar tokens desde una fuente intermedia es maquinaria para un problema que `--tk-*` resuelve en CSS plano.
- **`next-themes` para cambio de marca.** El branding es compile-time (override de `--tk-*`); una librería de runtime solo se justifica para un **toggle de usuario** de dark mode, no para fijar la marca de un proyecto.

Si algún día una de estas piezas resuelve un problema real que el setup mínimo no cubre, su adopción es una **escalación consciente** —se reabre la decisión que aquí se cerró—, no el camino por defecto.

### Escalaciones con disparador (no son default)

Distinto de la lista de arriba —piezas que se evitan—, estas son palancas que el setup base **no** activa pero tienen un disparador legítimo. Documentarlas evita el sub-engineering (sufrir el problema sin nombre) y el over-engineering (subirlas sin que el disparador haya llegado):

- **Librería de charting (data-viz).** El componente `chart` de shadcn/ui (Recharts debajo). **Disparador:** el producto necesita visualización de datos real —series, distribuciones, un dashboard con gráficos—. Es la única dependencia de cliente pesada del frontend; hasta que el disparador llega, KPIs y tablas se rinden con HTML server-side. El dato siempre se computa en el servidor y cruza como prop serializable; la librería solo entra para el **canvas**.
- **Caching de lectura entre requests.** Una página de dominio es `force-dynamic` y `cache()` de React solo deduplica **dentro** de un render, no entre requests. Un dashboard muy interactivo —cada ajuste de filtro re-ejecuta todas las consultas— puede pagar latencia repetida en agregaciones costosas. **Disparador:** una serie o agregación cara que cambia poco y se consulta seguido bajo filtros muy interactivos. La palanca es `unstable_cache`/`revalidateTag` para esas lecturas concretas, invalidadas por el `revalidateTag` que ya disparan las mutaciones del recurso. No es un cache global ni un default: se aplica a la query que el profiling señale, no a la página entera.
- **Paginación por cursor.** El default es offset (`page`/`pageSize`). **Disparador:** datasets grandes donde el `OFFSET` se vuelve caro, o scroll infinito. Cambia el shape de la query de lectura sin tocar el resto del patrón de dashboard.
- **`searchParams`-as-state con utilidad dedicada.** Construir y sincronizar query strings a mano en cada isla de filtro funciona para pocos params; cuando un dashboard tiene muchos filtros que coordinar, **el disparador** es la repetición, y la palanca es una utilidad compartida en `shared/` (o una librería única de URL-state, evaluada contra `una herramienta por área`). Mantiene un solo camino correcto para filtro→URL→re-render server.
- **Paquete de tokens compartido (multi-proyecto).** Un paquete npm privado con un `theme.css` de **solo tokens** (primitivas `--tk-*` + `@theme inline`, sin `@import "tailwindcss"`) que cada repo polyrepo importa tras Tailwind, con `@source` apuntando al paquete para sobrevivir el purge, branding por override de ~5 primitivas por proyecto y un registry shadcn privado como on-ramp de componentes. **Disparador:** un segundo proyecto que comparte identidad visual. Para un proyecto único, los tokens viven directamente en su `globals.css`.
