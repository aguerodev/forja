---
id: ops.entornos-imagen
titulo: Entornos e imagen Docker
tipo: referencia
tier: 3
audience: both
resumen: Definición de los entornos dev y prod, la convención APP/PUBLIC_NAME para hostnames y nombres de stack, y el Dockerfile multi-stage que emite las tres imágenes del stack.
provides:
  - dos entornos (dev = next dev contra localhost:3000; prod = stack en Swarm)
  - ausencia deliberada de staging (es una decisión, no un olvido)
  - staging riel (ENV=test precableado en deploy.sh, off por defecto; el pipeline vive en ops.pipeline-cicd)
  - distinción APP vs PUBLIC_NAME (APP = slug de stack/imagen; PUBLIC_NAME = label DNS público; un '_' en un hostname es inválido)
  - convención de hostnames por entorno (${PUBLIC_NAME}.<dominio> prod; dev-${PUBLIC_NAME}.<dominio> test)
  - patrón de nombre de stack ${APP}_<env>
  - docker context de prod fijado en deploy.sh (${APP}-prod); test neutraliza DOCKER_CONTEXT y usa el contexto local
  - Dockerfile multi-stage (base / deps / builder / runner / migrator / backup)
  - tres imágenes por --target (runner → ${APP}:latest; migrator → ${APP}:migrate; backup → ${APP}:backup)
  - Node alpine + pnpm vía Corepack (packageManager; --frozen-lockfile)
  - secretos placeholder en la etapa builder (dummies en /run/secrets para next build, borrados en la misma capa)
  - ARG GIT_SHA → ENV BUILD_SHA (lo devuelve /api/health para verificar la versión servida en deploy y rollback)
  - usuario sin privilegios nextjs uid 1001 (HOSTNAME=0.0.0.0; PORT=8000; NODE_ENV=production)
  - sin HEALTHCHECK a nivel de imagen (la readiness vive en stack.yml y gobierna el rollback)
  - imagen migrator separada cuyo CMD es node_modules/.bin/drizzle-kit migrate (node_modules completo + drizzle.config.ts + migraciones)
  - la capa deps cachea solo el contrato (package.json + lockfile)
  - .next/standalone con .next/static y public/ copiados aparte
  - bootstrap local (nvm + corepack + pnpm install + secretos dev + postgres:17 + db:migrate + next dev)
reads-before: [ops.modelo-operacion]
related: []
---

# Entornos e imagen Docker

Entornos que el proyecto despliega e imágenes Docker que los sirven. La topología que recibe las imágenes en producción: [Modelo de operación](./01_explicacion-modelo-operacion.md). Para la sección de imagen, el `Dockerfile` en la raíz del repo es la **fuente de verdad**: ante divergencia, gana el archivo.

## Norma

### Dos entornos activos, deliberadamente

El proyecto define **dos entornos activos**: `dev` (local) y `prod` (server).

- **dev = el loop de desarrollo, no infraestructura.** El dev server de Next (`pnpm dev`, hot reload) contra `localhost:3000`, leyendo `.env` y los secretos dev-local (ver [Bootstrap local](#bootstrap-local)). Si se necesita **tráfico entrante** con dominio real (webhooks, OAuth, compartir un preview), el riel `ENV=test` de `deploy.sh` despliega el stack completo en el Swarm local, expuesto como `dev-${PUBLIC_NAME}.<dominio>`.
- **prod = el stack en Swarm.** Corre como Docker Stack en el nodo de producción, expuesto por su dominio público vía Cloudflare Tunnel, con backups.

### Ausencia deliberada de staging

**No hay staging — es una decisión, no un olvido.** Un staging existe para proteger algo valioso; pre-lanzamiento, prod no tiene datos ni usuarios que perder, así que un escalón intermedio sería ceremonia sin riesgo que la justifique ([ceremonia proporcional al riesgo](../fundamentos/01_explicacion-principios.md)).

El **riel de staging queda precableado pero apagado**: `deploy.sh` acepta `ENV=test` y despliega el mismo stack en el Swarm local. El detalle del pipeline, los gates y el release vive en [Release por comando](./08_how-to-pipeline-cicd.md) y no se re-documenta acá. Encender un entorno intermedio real es una **escalación deliberada**, no el default.

### Convención de hostnames y nombres (dos nombres, una app)

`deploy.sh` separa dos identificadores que no deben fundirse en uno:

- **`APP` (`app_shorter`) = slug de stack e imagen.** Nombra el stack (`${APP}_prod`), las imágenes (`${APP}:latest`) y el prefijo de los Docker secrets. El guión bajo es válido en todos esos espacios.
- **`PUBLIC_NAME` (`shorter`) = label DNS público.** Un `_` en un hostname es **inválido** (Cloudflare lo rechaza), así que el host público deriva **siempre** de `PUBLIC_NAME`, nunca de `APP`.

| Entorno | Hostname público | Stack | Docker context |
|---|---|---|---|
| prod | `${PUBLIC_NAME}.<dominio>` | `${APP}_prod` | `${APP}-prod` (fijado en `deploy.sh`) |
| test (riel local) | `dev-${PUBLIC_NAME}.<dominio>` | `${APP}_test` | — (contexto local activo) |

- **Patrón de nombre de stack:** `${APP}_<env>` (p. ej. `${APP}_prod`).
- En `ENV=test`, `deploy.sh` **neutraliza** cualquier `DOCKER_CONTEXT` heredado: un deploy de test nunca puede redirigirse al nodo de producción.

### Un Dockerfile, tres imágenes

Un único `Dockerfile` multi-stage (etapas `base / deps / builder / runner / migrator / backup`) emite **tres imágenes** vía `--target` (fase 1 de `deploy.sh`):

| `--target` | Tag local | Rol |
|---|---|---|
| `runner` | `${APP}:latest` | Servidor Next standalone (servicio `app`) |
| `migrator` | `${APP}:migrate` | One-shot de migraciones (servicio `migrate`) |
| `backup` | `${APP}:backup` | Sidecar de backups (servicio `backup`; ver [Backups](./09_how-to-backups.md)) |

Principios estructurales:

- **La capa `deps` cachea solo el contrato.** Copia `package.json` + `pnpm-lock.yaml` (no el código) antes de `pnpm install --frozen-lockfile`: editar código invalida solo las capas posteriores (baratas), no la instalación de dependencias.
- **Las migraciones corren desde una imagen separada.** El bundle standalone del `runner` solo traza dependencias de runtime; `drizzle-kit` es devDependency y no viaja en él. La imagen `migrator` copia el `node_modules` completo de `deps` + `drizzle.config.ts` + las migraciones versionadas, y su `CMD` es `node_modules/.bin/drizzle-kit migrate` (lee `db_url` desde `/run/secrets/db_url`).
- **Secretos placeholder en `builder`.** `next build` evalúa módulos de servidor durante "collect page data", y esos módulos ejecutan `getConfig()`: la etapa escribe un archivo dummy por **cada campo** del schema de config en `/run/secrets`, corre el build y los borra en la **misma capa** (ningún placeholder llega a la imagen). Un campo nuevo en `configSchema` exige su placeholder, o el build falla.
- **`BUILD_SHA` horneado en el `runner`.** `--build-arg GIT_SHA=<commit>` → `ENV BUILD_SHA`; `/api/health` lo devuelve como `sha` para confirmar que la versión servida es la recién desplegada — o la restaurada tras un rollback.
- **Sin `HEALTHCHECK` a nivel de imagen.** La única sonda es la readiness del bloque `healthcheck` de `stack.yml` (`/api/health` = `SELECT 1` al pool con timeout de 1 s), y es esa la que gobierna `start-first` + `failure_action: rollback` (ver [Modelo de operación](./01_explicacion-modelo-operacion.md)).

## Camino verificado

### Tabla de entornos aplicada

| | dev (local) | prod (server) |
|---|---|---|
| Dónde corre | Tu equipo | `<VPS>` |
| Cómo | `pnpm dev` contra `localhost:3000` | Stack en Swarm |
| Dominio | `localhost` | `${PUBLIC_NAME}.<dominio>` |
| Stack | — | `${APP}_prod` |
| Docker context | — | `${APP}-prod` |
| Réplicas app | — | 1 |
| Backups | — | sí ([Backups](./09_how-to-backups.md)) |

### Bootstrap local

El camino desde un clone limpio hasta la app corriendo en tu equipo:

1. `nvm use` (`.nvmrc` fija Node 22) y `corepack enable pnpm` (versión fijada por `packageManager`); luego `pnpm install`.
2. Config del runtime: `src/core/config.ts` lee cada campo **solo** como archivo en `/run/secrets/` (el fallback a variables de entorno del [patrón de convenciones](../arquitectura/03_referencia-convenciones-codigo.md) no está implementado): materializa un archivo dev-local por campo — `db_url`, `session_secret`, `webhook_secret`, `resend_api_key`, `resend_from`, `app_base_url`, `ip_pepper`, `admin_email`, `admin_password` (mínimos del schema: 32 chars los secrets, 12 el password).
3. `.env` (gitignored) para lo que sí es variable de entorno: `BETTER_AUTH_URL=http://localhost:3000`, `TRUSTED_ORIGINS=http://localhost:3000`, `COOKIE_SECURE=false`.
4. Postgres local (no hay compose de dev; `stack.yml` es Swarm): `docker run -d -p 5432:5432 -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=app_shorter postgres:17`.
5. Migraciones: `DATABASE_URL=postgres://app:app@localhost:5432/app_shorter pnpm db:migrate` (= `drizzle-kit migrate`; `drizzle.config.ts` toma `DATABASE_URL` de `process.env`).
6. `pnpm dev` → `http://localhost:3000`.
7. `pnpm test:integration` usa testcontainers: requiere el daemon de Docker corriendo.

### Dockerfile multi-stage

> Copia literal del `Dockerfile` del repo (el archivo es la fuente de verdad). La versión de Node va fijada a la LTS del proyecto (`.nvmrc` = 22; `engines` en `package.json`).

```dockerfile
FROM node:22-alpine AS base
RUN corepack enable pnpm

# Stage 1: install dependencies
FROM base AS deps
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# Stage 2: build Next.js
FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
# Provide placeholder secrets so Next.js can evaluate server modules during
# the "collect page data" build step. Real secrets are Docker secrets at runtime.
# Add a placeholder for every field in src/core/config.ts configSchema.
RUN mkdir -p /run/secrets \
    && printf 'postgres://dummy:dummy@localhost:5432/dummy' > /run/secrets/db_url \
    && printf 'build-time-placeholder-secret-32-chars-min' > /run/secrets/session_secret \
    && printf 'build-time-placeholder-wh-secret-32-chars' > /run/secrets/webhook_secret \
    && printf 're_build_placeholder_api_key' > /run/secrets/resend_api_key \
    && printf 'build-placeholder@example.com' > /run/secrets/resend_from \
    && printf 'https://build-placeholder.example.com' > /run/secrets/app_base_url \
    && printf 'build-time-placeholder-ip-pepper-32-chars-min' > /run/secrets/ip_pepper \
    && printf 'admin-build-placeholder@example.com' > /run/secrets/admin_email \
    && printf 'admin-build-placeholder-password-min12' > /run/secrets/admin_password \
    && pnpm exec next build \
    && rm -rf /run/secrets

# Stage 3: production runner (uses Next.js standalone output)
FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
# Build commit, surfaced by /api/health so a deploy can confirm the new artifact
# is serving. CI passes --build-arg GIT_SHA=<commit>; empty for local builds.
ARG GIT_SHA=""
ENV BUILD_SHA=$GIT_SHA

RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
# Copy public dir only if it exists (no-op when the project has none).
RUN --mount=from=builder,source=/app,target=/builder \
    if [ -d /builder/public ]; then cp -r /builder/public /app/public && chown -R nextjs:nodejs /app/public; fi

USER nextjs
EXPOSE 8000
ENV PORT=8000
ENV HOSTNAME="0.0.0.0"
CMD ["node", "server.js"]

# Stage 4: migration runner
# Runs drizzle-kit migrate as a one-shot container.
# drizzle.config.ts reads db_url from /run/secrets/db_url (Docker secret).
FROM base AS migrator
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY drizzle.config.ts ./
COPY src/core/db/migrations ./src/core/db/migrations
ENV NODE_ENV=production
CMD ["node_modules/.bin/drizzle-kit", "migrate"]

# Stage 5: backup sidecar (doctrine: wiki/operaciones/09)
# Daily pg_dump of the stack's database, 7-day rotation, off-site upload.
# Based on the SAME postgres major as the db service: pg_dump must not be older
# than the server it dumps.
FROM postgres:17 AS backup
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/*
COPY scripts/db-backup.sh /usr/local/bin/db-backup.sh
# /backups pre-created and owned here so the named volume inherits the ownership
# on first mount (a root-owned volume would be unwritable for USER postgres).
RUN chmod +x /usr/local/bin/db-backup.sh \
    && mkdir -p /backups && chown postgres:postgres /backups
# Non-root: the postgres image ships a 'postgres' user; the sidecar needs no root.
USER postgres
ENTRYPOINT ["/usr/local/bin/db-backup.sh"]
```

### Notas del Dockerfile

- **Tres builds del mismo archivo** (fase 1 de `deploy.sh`): `docker build --target runner|migrator|backup` con tags `${APP}:latest`, `${APP}:migrate`, `${APP}:backup`; el `runner` recibe `--build-arg GIT_SHA="$(git rev-parse HEAD)"`.
- **`--frozen-lockfile`** hace fallar el build si `pnpm-lock.yaml` quedó desactualizado respecto a `package.json`: la imagen instala exactamente lo del lockfile, igual que CI y que tu máquina.
- **`output: "standalone"` en `next.config.ts`** sostiene el `runner`: `next build` traza el grafo de imports y emite un `server.js` autocontenido con un `node_modules` mínimo de solo las dependencias de runtime usadas. Por eso el `runner` no lleva `pnpm` ni `devDependencies`. `.next/static` se copia aparte, y `public/` de forma **condicional** (un `RUN --mount` bind desde `builder`: no-op si el proyecto no tiene `public/`).
- **`BUILD_SHA` en la práctica.** CI pasa `--build-arg GIT_SHA=<commit>`; un build local sin el arg lo deja vacío y el selector de rollback (`scripts/release/versions.sh`) muestra `(no build sha)`; el dev server (sin la variable) reporta `sha: "dev"`.
- **El `migrator` corre como job gateado.** `stack.yml` lo declara `mode: replicated-job` y `deploy.sh` espera su `Complete` antes de rolar la app; el detalle de la migración gateada vive en [Release por comando](./08_how-to-pipeline-cicd.md).
- **`PORT=8000` y `HOSTNAME="0.0.0.0"`** los lee el `server.js` standalone. `8000` debe coincidir con el target del ingress del túnel (`stack.yml` fija `PORT: "8000"` por esa razón). Sobreescribir `HOSTNAME` es necesario porque Docker define esa variable con el id del contenedor; sin eso, el server bindearía a un host inválido.
- **Usuario sin privilegios** `nextjs` (uid 1001, grupo `nodejs` gid 1001): el `runner` no corre como root; artefactos copiados con `--chown=nextjs:nodejs`.
- **La etapa `backup` parte de `postgres:17`**, el mismo major que el servicio `db`: un `pg_dump` no puede ser más viejo que el servidor que respalda. Doctrina completa en [Backups](./09_how-to-backups.md).
- **Las imágenes se construyen en el nodo que despliega vía el docker context** (build-on-node, sin registry): con un solo nodo, la imagen construida es exactamente la que ese nodo corre. El camino local usa tags mutables y un force-roll del servicio para que el rolling detecte la imagen nueva. Publicar en GHCR tageada por SHA y consumir por digest es la **entrada del dial** para cuando el build deje de ocurrir en la máquina que despliega. Ver [Modelo de operación](./01_explicacion-modelo-operacion.md) y [Release por comando](./08_how-to-pipeline-cicd.md).
