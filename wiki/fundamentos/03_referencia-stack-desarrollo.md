---
id: fund.stack
titulo: Stack de desarrollo
tipo: referencia
tier: 0
audience: both
resumen: Catálogo de una herramienta por área del stack de desarrollo, con su versión canónica y el porqué de las elecciones clave.
provides:
  - "una elección de herramienta por área"
  - "catálogo canónico del stack de desarrollo"
  - "PostgreSQL como versión mayor fijada antes de crear el volumen de prod"
  - "Socket / análisis de supply-chain como entrada del dial"
reads-before: [fund.principios]
related: [arq.testing, arq.estilos-frontend]
---

# Referencia del stack de desarrollo

Una elección de herramienta por área, con su línea mayor. Las **versiones exactas y reproducibles** viven en `pnpm-lock.yaml`; esta tabla fija las **líneas mayores**.

Las versiones son la **línea actual**, no una constante: un parámetro del proyecto. Lo que no caduca es el **principio organizador**: una sola elección por área, con un porqué explícito. El razonamiento de fondo está en [Los principios del proyecto](./01_explicacion-principios.md) y [La arquitectura por dentro](../arquitectura/01_explicacion-arquitectura-hexagonal.md).

## Elecciones por área

| Área                        | Elección (única)             | Versión (actual) | Para qué                                                                       |
| --------------------------- | ---------------------------- | ---------------- | ------------------------------------------------------------------------------ |
| Lenguaje                    | TypeScript                   | 5.x              | Tipado estático nativo sobre el ecosistema JS                                  |
| Gestor de proyecto/paquetes | pnpm                         | 9.x              | `package.json` + `pnpm-lock.yaml`, store content-addressable                   |
| Framework / API             | Next.js (App Router)         | 15.x             | UI server-side + Route Handlers/Server Actions; un solo desplegable            |
| Validación / contrato       | Zod (+ zod-to-openapi)       | 4.x              | Schemas I/O; el esquema OpenAPI 3.1 generado es el contrato                    |
| ORM                         | Drizzle ORM                  | 0.x              | Acceso a datos detrás de un puerto; SQL-first, sin magia                       |
| Driver DB                   | node-postgres (`pg`)         | 8.x              | Conector PostgreSQL maduro de bajo nivel                                       |
| Migraciones                 | drizzle-kit                  | 0.x              | Cambios de esquema versionados, derivados del schema TS                        |
| Base de datos               | PostgreSQL                   | mayor fijada     | Persistencia relacional                                                        |
| Configuración               | Zod (módulo `config` propio) | —                | Configuración tipada desde el entorno y desde `/run/secrets`                  |
| Autenticación / sesión      | Better Auth                  | 1.x              | Sesiones en Postgres, email/password + OAuth, hashing Argon2id                |
| Tests                       | Vitest (+ coverage-v8)       | 3.x              | Unidad e integración; ESM-nativo, watch rápido                                |
| Property-based              | fast-check                   | —                | Invariantes del dominio                                                        |
| Aislamiento de BD en tests  | testcontainers-node          | —                | PostgreSQL real y efímera                                                      |
| Fuzzing de contrato         | Schemathesis                 | —                | Tests contra el esquema OpenAPI generado por zod-to-openapi                    |
| Mutation testing            | Stryker                      | —                | Calidad de los tests del dominio — MÉTRICA, job nightly (no gate de merge)     |
| E2E                         | Playwright                   | —                | Flujos críticos en navegador                                                   |
| Tipado estático             | TypeScript `strict`          | —                | `tsc --noEmit` como gate; red de seguridad del propio lenguaje                |
| Lint + format               | Biome                        | —                | Lint y formato en un único binario                                            |
| Seguridad estática + deps   | reglas `security` de Biome + pnpm audit | —     | Análisis de seguridad del código y auditoría del árbol de dependencias |
| Pureza arquitectónica       | dependency-cruiser           | —                | Impone la regla de dependencias en CI                                          |
| Logs                        | pino                         | —                | JSON estructurado con id de request                                            |
| Errores                     | @sentry/nextjs               | —                | Reporte agregado de excepciones (server + cliente, unificado)                  |
| Scaffolding                 | Plop                         | —                | El proyecto y cada feature nacen correctos                                     |
| Comando único               | `pnpm run check`             | —                | Corre todos los gates (local = CI)                                             |
| IA                          | Agente de IA + gentle-ai     | —                | Flujo SDD/TDD                                                                  |

> La columna **Versión (actual)** es la línea vigente. Al arrancar un proyecto se fija a la línea mayor a usar y se ancla en `pnpm-lock.yaml`; la doctrina es "una línea mayor por área", no el número concreto.

## Notas de las decisiones

- **PostgreSQL: la mayor se fija antes de crear el volumen de prod.** La versión mayor se decide una sola vez, al inicio, y queda clavada como tag de la imagen de base de datos. Con datos ya escritos en el volumen, cambiar de mayor deja de ser un cambio de tag y se vuelve un `pg_upgrade`/dump-restore. Por eso es una precondición del primer despliegue, no un detalle posterior.
- **El I/O asíncrono es nativo.** El event loop hace todo el I/O asíncrono sin ceremonia; Drizzle es asíncrono y eso no añade complejidad. Lo que **sí** sube en el dial son streaming/SSE/websockets como features deliberadas (ver [Los principios del proyecto](./01_explicacion-principios.md#robusto-no-es-máximo)).
- **El contrato OpenAPI lo generan los schemas.** Los schemas Zod de cada Route Handler producen OpenAPI 3.1 vía `zod-to-openapi`: el esquema es la cara pública de la feature y el insumo de Schemathesis. El borde full-stack de Next.js conserva el contract testing.
- **pnpm como única herramienta de entorno.** Todo pasa por `pnpm add` / `pnpm install` y queda en un solo lockfile (`pnpm-lock.yaml`), sin gestores en paralelo. La imagen Docker se construye con `pnpm install --frozen-lockfile`.
- **TypeScript `strict` como único type-checker.** `strict: true` en `tsconfig.json` basta y `tsc --noEmit` es el gate. No se añade otro verificador.
- **Biome cubre lint y formato en un único binario**, fiel a "una herramienta por área". Caveat honesto: el análisis de seguridad estática no llega al alcance del lint/formato; se cubre con las reglas `security` de Biome (en crecimiento), `pnpm audit` para el árbol de dependencias y, si el dial lo pide, **`Socket` para supply chain**. Esta brecha está anotada deliberadamente: el análisis de supply-chain es una **entrada del dial**, no una pieza base.
- **dependency-cruiser impone la pureza arquitectónica.** Codifica cuatro contratos ejecutables (dominio puro como allowlist, orden de capas intra-slice, independencia entre features vía `public.ts` y frontera server-only) como gate de CI. Si la regla no es un gate, es prosa ignorable.
- **Better Auth cubre autenticación y sesión.** Es TS-first: el esquema de sesión y usuario es código TypeScript, persiste las sesiones en el mismo PostgreSQL del proyecto vía Drizzle, ofrece email/password y OAuth con un solo módulo, y hashea contraseñas con Argon2id interno. El módulo vive en `src/core/auth` y de su sesión verificada se deriva el `Actor` que consume la autorización deny-by-default. El detalle normativo —cookie, expiración/rotación, parámetros Argon2id, tablas Drizzle— está en [Autenticación y sesión](../arquitectura/05_referencia-auth-y-sesion.md).

## Stack de infraestructura

El stack de despliegue (servidor, Docker Engine, Swarm, Cloudflare Tunnel, GHCR, CI/CD, backups) se documenta en [Modelo de operación](../operaciones/01_explicacion-modelo-operacion.md). La infraestructura es **agnóstica al lenguaje**: salvo el Dockerfile (imagen Node multi-stage con usuario sin privilegios) y las pocas líneas que leen `/run/secrets`, las normas de despliegue son idénticas en cualquier proyecto.
