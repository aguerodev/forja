# Multi-stage image (doctrine: wiki ops/02 - load `forja:doctrina`).
# ONE Dockerfile emits THREE images via --target (deploy.sh phase 1):
#   runner   -> {{APP}}:latest   Next.js standalone server (service `app`)
#   migrator -> {{APP}}:migrate  one-shot drizzle migrations (service `migrate`)
#   backup   -> {{APP}}:backup   daily pg_dump sidecar (service `backup`)
# No image-level HEALTHCHECK: readiness lives in stack.yml and governs rollback.

FROM node:{{NODE_VERSION}}-alpine AS base
# corepack pins pnpm to the exact `packageManager` version in package.json —
# the version is a single datum, never redeclared here. The env var keeps the
# corepack download prompt from ever blocking a non-interactive build.
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable pnpm

# Stage 1: install dependencies
# The deps layer caches only the contract (package.json + lockfile): editing
# code invalidates the cheap later layers, not the dependency install.
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
# the "collect page data" build step. Real secrets are Docker secrets at
# runtime. Add a placeholder for EVERY field in src/core/config.ts
# ConfigSchema — a new field without its placeholder fails this build.
# Written and removed in the SAME layer: no placeholder reaches the image.
RUN mkdir -p /run/secrets \
    && printf 'postgres://dummy:dummy@localhost:5432/dummy' > /run/secrets/db_url \
    && printf 'build-time-placeholder-secret-32-chars-min' > /run/secrets/session_secret \
    && printf 'https://build-placeholder.example.com' > /run/secrets/app_base_url \
    && pnpm exec next build \
    && rm -rf /run/secrets

# Stage 3: production runner (uses Next.js standalone output)
FROM node:{{NODE_VERSION}}-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
# Build commit, surfaced by /api/health so a deploy can confirm the new
# artifact is serving (and a rollback the restored one). deploy.sh passes
# --build-arg GIT_SHA=<commit>; empty for local builds.
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
# server.js reads PORT/HOSTNAME. 8000 must match the tunnel ingress target
# (stack.yml re-fixes PORT for that reason). HOSTNAME is overridden because
# Docker defines that variable with the container id; without this the
# standalone server would bind to an invalid host.
ENV PORT=8000
ENV HOSTNAME="0.0.0.0"
CMD ["node", "server.js"]

# Stage 4: migration runner
# Runs drizzle-kit migrate as a one-shot container (service `migrate`,
# mode replicated-job in stack.yml, gated by deploy.sh). drizzle-kit is a
# devDependency and does not travel in the standalone runner bundle, so this
# image copies the FULL node_modules from deps + config + versioned
# migrations. drizzle.config.ts reads db_url from /run/secrets/db_url.
FROM base AS migrator
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY drizzle.config.ts ./
COPY src/core/db/migrations ./src/core/db/migrations
ENV NODE_ENV=production
CMD ["node_modules/.bin/drizzle-kit", "migrate"]

# Stage 5: backup sidecar (doctrine: wiki ops/09)
# Daily pg_dump of the stack's database, validated with pg_restore --list,
# 7-day rotation local + off-site upload (SFTP, port 23). Based on the SAME
# postgres major as the db service: pg_dump must not be older than the server
# it dumps.
FROM postgres:{{PG_MAJOR}} AS backup
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/*
COPY scripts/db-backup.sh /usr/local/bin/db-backup.sh
# /backups pre-created and owned here so the named volume inherits the
# ownership on first mount (a root-owned volume would be unwritable for
# USER postgres).
RUN chmod +x /usr/local/bin/db-backup.sh \
    && mkdir -p /backups && chown postgres:postgres /backups
# Non-root: the postgres image ships a 'postgres' user; the sidecar needs no root.
USER postgres
ENTRYPOINT ["/usr/local/bin/db-backup.sh"]
