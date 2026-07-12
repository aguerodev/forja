---
id: ops.pipeline-cicd
titulo: Release por comando y CI de gates
tipo: how-to
tier: 3
audience: both
resumen: El modelo de entrega — gates en el PR vía CI, ship por el comando /forja:deploy del operador — con el orden canónico de release, los dos planos de rollback y la disciplina expand/contract.
provides:
  - "gate en el PR, ship por comando (/forja:deploy) — el CI verifica, no despliega"
  - "orden canónico de release (release/* -> main -> /forja:deploy -> registro -> back-merge)"
  - "preflight como provenance gate (rama main, tree limpio, al día con origin, gates verdes, confirmación explícita)"
  - "salvaguardas del deploy (working tree sucio, confirmación explícita; secrets: preflight blando + aserción dura REQUIRED_SECRETS contra el swarm)"
  - "migración como replicated-job declarado en stack.yml (lo lanza el propio docker stack deploy; deploy.sh la gatea con polling del estado de la task)"
  - "disciplina expand/contract (migración destructiva en dos deploys; las dos versiones conviven durante el rolling)"
  - "regla de polling del estado de la task para jobs one-shot"
  - "rollback en dos planos (software: service rollback barato y automático-ofrecible; datos: pg_restore destructivo, human-confirmed)"
  - "el tag vX.Y.Z como registro del release, no como trigger; su cuerpo anotado ES el changelog generado (git log <prev>..HEAD; se lee con git tag -n99)"
  - "capas del release: comando delgado sobre scripts deterministas; gates humanos sin scriptear"
  - "comandos del operador en el plugin forja (deploy y rollback; scripts deterministas en el proyecto)"
  - "interfaz de operación por entorno (/forja:deploy preview|production y /forja:rollback preview|production; preview = swarm local)"
  - "rollback multi-versión (tags post-health, descripción por commit, regreso con latest)"
  - "jobs de verificación del CI del proyecto como gates de PR (check del contrato, integration, contract; mutation nightly)"
  - "concurrency (cancel-in-progress true para check; los deploys no se serializan en CI porque el ship es manual y humano)"
  - "deploy vía CI/GitHub Actions como entrada del dial (disparador: más de un operador desplegando a la vez o auditoría de release exigida)"
  - "lección del pipeline por tag (provenance gate + GHCR durable: tres tandas de fixes para un flujo que una persona ejecuta en minutos)"
reads-before: [ops.secretos, ops.desplegar-swarm]
related: [ops.backups]
---

# Release por comando y CI de gates

El modelo de entrega separa dos responsabilidades que antes vivían juntas:

- **El CI verifica** (GitHub Actions): los gates corren en cada PR y bloquean el merge. El CI **no despliega**.
- **El operador embarca** (comando `/forja:deploy` de Claude Code): cuando la versión está probada en dev, el operador corre `/forja:deploy` desde su máquina y el release completo —preflight, backup, deploy, verificación, rollback si hace falta— ocurre en una sola operación conducida.

Este doc fija la **norma** portable del release y el **camino verificado** con la evidencia de por qué se abandonó el deploy por CI.

---

## Norma

### Gate en el PR, ship por comando

Los gates de PR no cambian y siguen siendo innegociables: `check` (el comando `check` del contrato, idéntico a local, que incluye el linter expand/contract de migraciones), `integration` (testcontainers contra la misma major de Postgres que prod) y `contract` (smoke del contrato de API + el **único build pre-merge** del sistema) bloquean el merge; `mutation` corre nightly como métrica. Lo que cambia es el ship: **ningún push, merge ni tag dispara un deploy**. Desplegar es un acto deliberado del operador.

La razón de fondo es de proporcionalidad ([robusto no es máximo](../fundamentos/01_explicacion-principios.md#robusto-no-es-máximo)): para un equipo chico donde quien mergea es quien despliega, un pipeline de entrega remoto duplica en YAML —con secretos de deploy en GitHub, auth durable al registry y gates de procedencia— lo que un comando local hace con las credenciales que el operador ya tiene. La evidencia está en el [camino verificado](#lección-verificada-el-pipeline-por-tag).

### El preflight ES el provenance gate

En el plan free de GitHub no hay branch protection en repos privados: nada impide técnicamente pushear a `main` o desplegar una rama cualquiera. El control real vive en el **preflight del comando `/forja:deploy`**, que aborta si no se cumple TODO:

1. Rama actual `main`, working tree limpio.
2. `HEAD` == `origin/main` (ni adelantado ni atrasado).
3. El comando `check` del contrato (default `pnpm run check`) verde en la máquina del operador.
4. Secrets de prod presentes (archivo local o ya bootstrapeados en el swarm) — mitad **blanda** del control: la aserción dura es el chequeo de `REQUIRED_SECRETS` que `deploy.sh` hace contra el swarm antes de tocar la base.
5. Confirmación explícita del operador (escribir `prod`).

La regla de Gitflow "solo `main` llega a producción" deja de ser prosa: es un exit code del comando.

### El comando conduce, el script decide

Cada fase del release es un **script determinista** en `scripts/release/` con salida `[PASS]`/`[FAIL]` y exit code; el comando del plugin (`/forja:deploy`, `/forja:rollback`) es un conductor delgado que ejecuta scripts en orden y actúa según el código de salida. Es el principio de [guardarraíles ejecutables](../fundamentos/01_explicacion-principios.md) aplicado al release: la lógica no vive en prosa que un modelo de lenguaje interpreta, vive en una herramienta que decide igual todas las veces.

Lo único que NUNCA se scriptea son los **gates humanos**: confirmar `prod` antes de desplegar, `rollback` antes de revertir producción y `restaurar datos` antes de tocar el plano de datos. Un guardarraíl que importa se prueba también en negativo: los scripts se validan verificando que **fallan** cuando deben (preflight fuera de `main`, verify con SHA equivocado), no solo que pasan.

La interfaz del operador queda por entorno: **`/forja:deploy preview|production`** y **`/forja:rollback preview|production`**, donde `preview` es el swarm local (`<dev>-${PUBLIC_NAME}.<dominio>`, por developer) sin gates de procedencia — existe justamente para probar trabajo en curso — y `production` exige el protocolo completo.

### Orden canónico de un release

El release empieza en Gitflow, no en el deploy — tres pasos previos (el modelo de ramas vive en [Trabajar con agentes §Gitflow](../proceso/01_explicacion-trabajo-con-ia.md)):

- **a.** Cortar `release/<versión>` desde `develop` y hacer ahí el **bump de `package.json`**.
- **b.** PR `release/<versión>` → `main` con los gates verdes; merge.
- **c.** `git checkout main && git pull` en la máquina del operador — recién ahí corre `/forja:deploy`.

`/forja:deploy` conduce; `deploy.sh prod` ejecuta las fases contra el nodo (vía docker context). La secuencia completa:

1. **Preflight** (arriba). Aborta barato, antes de tocar nada.
2. **Build en el nodo** vía el context del entorno ([Desplegar el stack en Swarm](./06_how-to-desplegar-swarm.md)).
3. **Secrets idempotentes** + aserción de que TODOS los requeridos existen antes de tocar la base.
4. **Backup pre-migración** (`pg_dump -Fc` validado con `pg_restore --list`; un dump inválido o una `db` ausente abortan — no hay migración sin punto de restore). Ver [Backups](./09_how-to-backups.md).
5. **Migración gateada**: `migrate` es un **replicated-job declarado en `stack.yml`** — lo lanza el propio `docker stack deploy`, y `deploy.sh` hace polling del estado de su task (ver la regla de abajo): `Complete` continúa; `Failed`/`Rejected` o el timeout abortan con el backup como punto de restore. En el primer arranque de un stack la app reinicia hasta que la migración corre; es esperado.
6. **Rolling deploy** con `order: start-first` y `failure_action: rollback`.
7. **Verificación**: health node-side (autoritativo, fatal) + sonda del edge público (warn-only, porque fusiona los dominios de fallo de la app, el túnel y Cloudflare).
8. **Tag de rollback**: solo una versión que llegó **sana** entra al historial — `deploy.sh` taggea la imagen como `<env>-<utc-ts>` (y `v<version>` en prod), reteniendo las últimas 5 (ver rollback multi-versión abajo).
9. **Off-site**: el dump del paso 4 se sube al Storage Box de Hetzner **vía el nodo** (el puerto 23 suele estar bloqueado en la red del operador) — fuera del proyecto cloud del server, cumpliendo la regla de blast radius de [Backups](./09_how-to-backups.md).
10. **Registro**: se corta el tag git `vX.Y.Z` (== versión de `package.json`) como **marca de qué quedó en prod**. El tag es registro, **no** trigger. El preflight exige que el tag de la versión esté **libre**, lo que fuerza el bump de versión antes de cada release. **El tag anotado ES el changelog**: `tag-release.sh` genera su cuerpo con los commits desde el tag anterior (`git log <prev>..HEAD`), así "qué cambió de vX a vY" se responde con `git tag -n99 vX.Y.Z` o `git show vX.Y.Z` — sin `CHANGELOG.md` a mano que se desactualice.
11. **Back-merge**: PR `main` → `develop` para que `develop` cargue el bump y los fixes del release. Sin esto, el próximo release nace mal numerado (ver [§Gitflow](../proceso/01_explicacion-trabajo-con-ia.md)).

### Rollback en dos planos — nunca mezclarlos

Un deploy fallido tiene dos remedios de costo radicalmente distinto, y el comando los trata por separado:

- **Software (barato, se ofrece de inmediato).** Es **multi-versión**: `versions.sh <env>` lista los tags de rollback con **la descripción del cambio de cada uno** (sha corto + mensaje de commit, resueltos desde el `BUILD_SHA` horneado en la imagen — cero metadata extra) y marca la versión corriendo; `rollback-to.sh <env> <tag>` re-apunta el servicio y espera health. Se regresa con `rollback-to.sh <env> latest`. `docker service rollback` (un paso atrás) y el `failure_action: rollback` del compose siguen siendo el camino instantáneo. No toca los datos, y **el próximo deploy supera cualquier rollback**: es un puente mientras se corrige, no un estado permanente.
- **Datos (destructivo, human-confirmed).** Restaurar el dump pre-migración **borra todo lo escrito después del deploy**. Se reserva para el caso en que la migración corrompió el esquema o los datos, exige que el operador confirme con la frase literal `restaurar datos` tras ver exactamente qué ventana temporal se pierde, y siempre va después del rollback de software (la imagen previa corriendo contra el esquema restaurado).

Confundir los planos es el error caro: revertir datos ante un health check fallido convierte un incidente de minutos en pérdida real de escrituras de usuarios.

El rollback de código es seguro **porque** la disciplina expand/contract (abajo) garantiza que la versión anterior funciona contra el esquema vigente; sin esa disciplina, el rollback multi-versión sería una ruleta.

### Disciplina de migración: expand/contract

La migración corre **una sola vez**, antes de rolar la app, y el deploy se aborta si falla. Para cambios **destructivos** se usa **expand/contract**: se agrega lo nuevo en un deploy, se migra el código, y se borra lo viejo en un deploy **posterior** — durante el rolling conviven las dos versiones del código y ambas deben funcionar contra el mismo esquema. El gate ejecutable que impide saltearse la disciplina es el linter de SQL destructivo/non-expand, integrado en el comando `check` del contrato; el snapshot prod-like es una escalación del dial.

### Por qué el resultado de un job one-shot se lee del estado de la task

El **estado de la task** (`docker service ps <stack>_migrate`) es el único árbitro del resultado: `Complete` continúa, `Failed`/`Rejected` aborta. Hoy `migrate` es un **replicated-job dentro de `stack.yml`** (el Swarm corre la task exactamente una vez y reintenta solo ante fallo): `docker stack deploy` lo lanza sin bloquear y `deploy.sh` corre el loop de polling con deadline.

La regla nació de un incidente con el mecanismo anterior (`docker service create` sin `--detach`): la CLI bloquea hasta que el servicio **converge** al estado objetivo de réplicas, y un job que termina a propósito **nunca converge**, así que esperaba indefinidamente con la migración ya terminada con éxito. El mecanismo cambió; la lección es permanente: el comportamiento de la CLI no sirve para inferir el resultado de un job one-shot.

### Reglas del CI (solo gates)

- **`check` cancela runs obsoletos** (`cancel-in-progress: true` por rama): un commit nuevo invalida el gate viejo.
- **No hay job de deploy que serializar**: el ship es manual y humano; dos operadores no despliegan a la vez porque el equipo es chico y el preflight exige `main` al día — si esto deja de alcanzar, ver el dial abajo.
- **Timeouts por job** y **actions pineadas** a tags inmutables o SHAs (misma higiene de supply chain que `pnpm audit`).
- **El CI no crea Docker secrets** ni tiene credenciales del nodo: sin clave SSH de deploy en GitHub, la superficie de secretos del repo se reduce a cero secretos de producción.

### DIAL: volver el deploy al CI

Deploy automatizado vía GitHub Actions (o cualquier runner remoto) queda como **escalación consciente**, no como default. Disparadores concretos:

| Disparador | Qué se sube |
|---|---|
| Más de un operador despliega y empiezan a pisarse, o hace falta desplegar sin la máquina de un operador | Job `deploy` en CI con environment gateado por aprobación humana, imagen por registry (GHCR por digest), `concurrency` que serializa sin cancelar migraciones |
| Auditoría/compliance exige trazabilidad de release independiente del operador | Deploy por tag con provenance gate (el commit del tag debe estar en `main`) |

Si se sube este escalón, el trabajo ya está hecho una vez: el riel del pipeline por tag existió y funcionó (ver abajo). Cada proyecto define su propio CI honrando "local = CI" con el comando `check` del contrato; el `ci.yml` de referencia del stack TS histórico se recupera del tag `ts-next-doctrine-final` del repo del plugin, no se diseña de cero.

---

## Camino verificado

### Los comandos y sus scripts

Los comandos son **`/forja:deploy`** y **`/forja:rollback`**, del plugin forja, y conducen; la verdad ejecutable vive en el repo del proyecto — `deploy.sh` y `scripts/release/`, instanciados por `/forja:init` — y lee el contexto del proyecto (app, context, host) desde el `.forja.json` commiteado. No hay copias por proyecto de los comandos que mantener sincronizadas: el plugin es la única fuente.

| Script | Fase | Qué decide |
|---|---|---|
| `lib.sh` | — | contexto compartido; `env_ctx production\|preview` resuelve stack/host/docker/túnel |
| `preflight.sh` | 0 | gates de procedencia (rama, tree, origin, tag libre, `check` del contrato) + resumen del release |
| `deploy.sh <env>` | 1 | build → secrets → backup validado → migración gateada → rolling → health → tags de rollback |
| `offsite-backup.sh` | 2 | dump al Storage Box **vía el nodo** (WARN sin abortar si falta `backup.env`) |
| `verify.sh` | 2 | SHA desplegado == HEAD (retry de edge + fallback node-side autoritativo) + smoke 200/404 |
| `tag-release.sh` | 2 | tag git anotado == versión de `package.json`, idempotente, solo desde `main` |
| `versions.sh` | rollback | lista candidatos con descripción por commit, marca el corriendo |
| `rollback-to.sh` | rollback | re-apunta el servicio a cualquier tag (o `latest`) y espera health |

Dos contratos finos que costaron un bug cada uno: el `BUILD_SHA` que describe cada versión se hornea en la imagen vía build-arg y lo expone `/api/health` con `Cache-Control: no-store` (así la verificación no puede ser engañada por el cache del edge); y al testear exit codes en bash, nunca medir `$?` después de un pipe — mide el del último comando del pipe, no el del script.

### Demo verificada: deploy y rollback por descripción

El flujo completo se ejercitó de punta a punta en preview con un cambio visible (el texto del hero de la home): `/forja:deploy preview` publicó el cambio en `dev-shorter`, `versions.sh` listó las versiones distinguidas por su commit (`77fdfea feat(home): hero text...` vs `e3afbc5 Merge PR #9...`), el rollback al tag anterior devolvió el texto viejo **verificado en el HTML servido** (no solo en el exit code), y `rollback-to.sh preview latest` restauró el nuevo. La verificación de un rollback es el contenido servido, no el comando que corrió.

### Lección verificada: el pipeline por tag

Antes de este modelo, el proyecto implementó el deploy remoto completo: push a `main` → build a GHCR por digest → provenance gate (el commit del tag debía estar en `main`, tag == versión de `package.json`) → deploy por SSH desde el runner, con auth durable de GHCR en el nodo y rollback por `workflow_dispatch`. Funcionó — y costó **tres tandas de fixes** (versiones de pnpm vs `packageManager`, puertos de postgres para el job de contrato, permisos de GHCR) para un flujo que una persona ejecuta localmente en minutos con credenciales que ya tiene.

La lección no es "CI/CD es malo": es que **el deploy remoto es un escalón del dial con costo fijo alto**, y pagarlo antes de que exista el síntoma (varios operadores, auditoría) es sobre-ingeniería. El gate del PR —que sí es barato y sí atrapa errores— se conserva íntegro.

### Incidente verificado: el job colgado

En una sesión real, el deploy quedó bloqueado sin actividad mientras `docker service ps <stack>_migrate` mostraba `Complete`: la migración había terminado con éxito en segundos, pero el proceso esperaba una convergencia que nunca llega para un job one-shot. Causa raíz y regla en la norma de arriba (el polling del estado de la task como único árbitro). Evidencia de por qué esa regla no es negociable.
