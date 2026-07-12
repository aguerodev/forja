---
id: ops.entornos-imagen
titulo: Entornos e imagen Docker
tipo: referencia
tier: 3
audience: both
resumen: Definición de los entornos dev y prod, la convención APP/PUBLIC_NAME para hostnames y nombres de stack, y el contrato de imagen multi-stage que emite las tres imágenes del stack.
provides:
  - dos entornos (dev = loop local del stack del proyecto; prod = stack en Swarm)
  - ausencia deliberada de staging (es una decisión, no un olvido)
  - staging riel (ENV=test precableado en deploy.sh, off por defecto; el pipeline vive en ops.pipeline-cicd)
  - distinción APP vs PUBLIC_NAME (APP = slug de stack/imagen; PUBLIC_NAME = label DNS público; un '_' en un hostname es inválido)
  - convención de hostnames por entorno (${PUBLIC_NAME}.<dominio> prod; <dev>-${PUBLIC_NAME}.<dominio> test, con <dev> = git config forja.devUser, fallback dev)
  - patrón de nombre de stack ${APP}_<env>
  - docker context de prod fijado en deploy.sh (${APP}-prod); test neutraliza DOCKER_CONTEXT y usa el contexto local
  - contrato de imagen multi-stage (targets runner / migrator / backup; el Dockerfile concreto es doctrina del stack de cada proyecto)
  - tres imágenes por --target (runner → ${APP}:latest; migrator → ${APP}:migrate; backup → ${APP}:backup)
  - la capa de dependencias cachea solo el contrato de dependencias (manifest + lockfile)
  - ARG GIT_SHA → ENV BUILD_SHA (lo devuelve el endpoint de health del contrato para verificar la versión servida en deploy y rollback)
  - usuario sin privilegios en el runner (la app nunca corre como root)
  - puerto interno del runner = runtime.port del contrato (.forja.json)
  - sin HEALTHCHECK a nivel de imagen (la readiness vive en stack.yml y gobierna el rollback)
  - imagen migrator separada cuyo CMD es el comando de migraciones del stack (lee db_url desde /run/secrets/db_url)
  - bootstrap local (comandos install/migrate/dev del contrato + postgres local en docker)
reads-before: [ops.modelo-operacion]
related: []
---

# Entornos e imagen Docker

Entornos que el proyecto despliega e imágenes Docker que los sirven. La topología que recibe las imágenes en producción: [Modelo de operación](./01_explicacion-modelo-operacion.md). Para la sección de imagen, el `Dockerfile` en la raíz del repo es la **fuente de verdad**: ante divergencia, gana el archivo.

## Norma

### Dos entornos activos, deliberadamente

El proyecto define **dos entornos activos**: `dev` (local) y `prod` (server).

- **dev = el loop de desarrollo, no infraestructura.** El dev server del stack (`commands.dev` del contrato, con hot reload) corriendo local, leyendo `.env` y los secretos dev-local (ver [Bootstrap local](#bootstrap-local)). Si se necesita **tráfico entrante** con dominio real (webhooks, OAuth, compartir un preview), el riel `ENV=test` de `deploy.sh` despliega el stack completo en el Swarm local, expuesto como `<dev>-${PUBLIC_NAME}.<dominio>` — un hostname **por developer** (el label sale de `git config forja.devUser`, fallback `dev`), para que dos personas puedan levantar su preview a la vez sin pisarse.
- **prod = el stack en Swarm.** Corre como Docker Stack en el nodo de producción, expuesto por su dominio público vía Cloudflare Tunnel, con backups.

### Ausencia deliberada de staging

**No hay staging — es una decisión, no un olvido.** Un staging existe para proteger algo valioso; pre-lanzamiento, prod no tiene datos ni usuarios que perder, así que un escalón intermedio sería ceremonia sin riesgo que la justifique ([ceremonia proporcional al riesgo](../fundamentos/01_explicacion-principios.md)).

El **riel de staging queda precableado pero apagado**: `deploy.sh` acepta `ENV=test` y despliega el mismo stack en el Swarm local. El detalle del pipeline, los gates y el release vive en [Release por comando](./08_how-to-pipeline-cicd.md) y no se re-documenta acá. Encender un entorno intermedio real es una **escalación deliberada**, no el default.

### Convención de hostnames y nombres (dos nombres, una app)

`deploy.sh` separa dos identificadores que no deben fundirse en uno:

- **`APP` = slug de stack e imagen.** Nombra el stack (`${APP}_prod`), las imágenes (`${APP}:latest`) y el prefijo de los Docker secrets. El guión bajo es válido en todos esos espacios.
- **`PUBLIC_NAME` = label DNS público.** Un `_` en un hostname es **inválido** (Cloudflare lo rechaza), así que el host público deriva **siempre** de `PUBLIC_NAME`, nunca de `APP`.

| Entorno | Hostname público | Stack | Docker context |
|---|---|---|---|
| prod | `${PUBLIC_NAME}.<dominio>` | `${APP}_prod` | `${APP}-prod` (fijado en `deploy.sh`) |
| test (riel local, por developer) | `<dev>-${PUBLIC_NAME}.<dominio>` | `${APP}_test` | — (contexto local activo) |

- **Patrón de nombre de stack:** `${APP}_<env>` (p. ej. `${APP}_prod`).
- En `ENV=test`, `deploy.sh` **neutraliza** cualquier `DOCKER_CONTEXT` heredado: un deploy de test nunca puede redirigirse al nodo de producción.

### Un Dockerfile, tres imágenes

Un único `Dockerfile` multi-stage emite **tres imágenes** vía `--target` (fase 1 de `deploy.sh`). El contenido de cada etapa es doctrina del stack de cada proyecto; los **targets y sus roles son el contrato fijo** que el pipeline asume:

| `--target` | Tag local | Rol |
|---|---|---|
| `runner` | `${APP}:latest` | El servidor de la app (servicio `app`) |
| `migrator` | `${APP}:migrate` | One-shot de migraciones (servicio `migrate`) |
| `backup` | `${APP}:backup` | Sidecar de backups (servicio `backup`; ver [Backups](./09_how-to-backups.md)) |

Principios estructurales:

- **La capa de dependencias cachea solo el contrato de dependencias.** Copia el manifest + lockfile (no el código) antes de instalar: editar código invalida solo las capas posteriores (baratas), no la instalación de dependencias.
- **Las migraciones corren desde una imagen separada.** El `runner` lleva solo dependencias de runtime; la imagen `migrator` empaqueta el tooling de migraciones del stack y su `CMD` es el comando de migración (lee `db_url` desde `/run/secrets/db_url`).
- **Secretos placeholder en `builder` si el build los exige.** Si el build del stack evalúa módulos de servidor que leen la config, la etapa `builder` escribe un placeholder por **cada campo** del schema de config en `/run/secrets`, corre el build y los borra en la **misma capa** (ningún placeholder llega a la imagen).
- **`BUILD_SHA` horneado en el `runner`.** `--build-arg GIT_SHA=<commit>` → `ENV BUILD_SHA`; el endpoint de health del contrato lo devuelve como `sha` para confirmar que la versión servida es la recién desplegada — o la restaurada tras un rollback.
- **Sin `HEALTHCHECK` a nivel de imagen.** La única sonda es la readiness del bloque `healthcheck` de `stack.yml` (el path de health del contrato respondiendo 200), y es esa la que gobierna `start-first` + `failure_action: rollback` (ver [Modelo de operación](./01_explicacion-modelo-operacion.md)).

## Camino verificado

### Tabla de entornos aplicada

| | dev (local) | prod (server) |
|---|---|---|
| Dónde corre | Tu equipo | `<VPS>` |
| Cómo | `commands.dev` del contrato en local | Stack en Swarm |
| Dominio | `localhost` | `${PUBLIC_NAME}.<dominio>` |
| Stack | — | `${APP}_prod` |
| Docker context | — | `${APP}-prod` |
| Réplicas app | — | 1 |
| Backups | — | sí ([Backups](./09_how-to-backups.md)) |

### Bootstrap local

El camino desde un clone limpio hasta la app corriendo en tu equipo (los comandos concretos los declara el contrato `.forja.json`):

1. Instalar el runtime del stack (la versión la fija el proyecto) y correr el comando `install` del contrato.
2. Config del runtime: la app lee cada campo de configuración **solo** como archivo en `/run/secrets/` — se materializa un archivo dev-local por cada campo del schema de config del proyecto.
3. `.env` (gitignored) para lo que sí es variable de entorno del stack en dev.
4. Postgres local (no hay compose de dev; `stack.yml` es Swarm): `docker run -d -p 5432:5432 -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=<db> postgres:<pgMajor>` (el major sale de `db.pgMajor` del contrato).
5. Migraciones: el comando `migrate` del contrato contra la base local.
6. El comando `dev` del contrato → la app en local.
7. Los tests de integración usan testcontainers: requieren el daemon de Docker corriendo.

### Contrato de imagen

El `Dockerfile` concreto viaja en el repo de cada proyecto (lo instancia `/forja:init` según el stack) y es la fuente de verdad. Lo que el pipeline exige de él, sea cual sea el stack:

- **Los tres targets** `runner` / `migrator` / `backup` existen y construyen (fase 1 de `deploy.sh`): `docker build --target runner|migrator|backup` con tags `${APP}:latest`, `${APP}:migrate`, `${APP}:backup`; el `runner` recibe `--build-arg GIT_SHA="$(git rev-parse HEAD)"`.
- **El `runner` escucha en `runtime.port` del contrato** (`EXPOSE` + la variable que su servidor lea): debe coincidir con el target del ingress del túnel — `stack.yml` fija el mismo puerto por esa razón.
- **El `runner` trae un comando de sonda** (`wget`, `curl` o el runtime del stack): el health node-side ejecuta dentro del contenedor; si la imagen no trae ninguno, el contrato define `runtime.healthcheckExec`.
- **El `runner` corre como usuario sin privilegios** (nunca root); los artefactos se copian con `--chown` a ese usuario.
- **Instalación congelada al lockfile**: el build falla si el lockfile quedó desactualizado respecto al manifest — la imagen instala exactamente lo del lockfile, igual que CI y que tu máquina.
- **El `migrator` corre como job gateado.** `stack.yml` lo declara `mode: replicated-job` y `deploy.sh` espera su `Complete` antes de rolar la app; el detalle de la migración gateada vive en [Release por comando](./08_how-to-pipeline-cicd.md).
- **La etapa `backup` parte de `postgres:<pgMajor>`**, el mismo major que el servicio `db`: un `pg_dump` no puede ser más viejo que el servidor que respalda. Copia `scripts/db-backup.sh`, corre como el usuario `postgres` (no root) y pre-crea `/backups` con ese owner para que el volumen herede el ownership en el primer mount. Doctrina completa en [Backups](./09_how-to-backups.md).
- **`BUILD_SHA` en la práctica.** CI pasa `--build-arg GIT_SHA=<commit>`; un build local sin el arg lo deja vacío y el selector de rollback (`scripts/release/versions.sh`) muestra `(no build sha)`; el dev server (sin la variable) reporta `sha: "dev"`.
- **Las imágenes se construyen en el nodo que despliega vía el docker context** (build-on-node, sin registry): con un solo nodo, la imagen construida es exactamente la que ese nodo corre. El camino local usa tags mutables y un force-roll del servicio para que el rolling detecte la imagen nueva. Publicar en un registry tageada por SHA y consumir por digest es la **entrada del dial** para cuando el build deje de ocurrir en la máquina que despliega. Ver [Modelo de operación](./01_explicacion-modelo-operacion.md) y [Release por comando](./08_how-to-pipeline-cicd.md).
