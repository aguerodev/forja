---
id: ops.desplegar-swarm
titulo: Desplegar el stack en Swarm
tipo: how-to
tier: 3
audience: both
resumen: Desplegar la app como stack de Swarm en ambos entornos con el mismo stack.yml y deploy.sh, incluyendo la transición de estado del túnel.
provides:
  - "deploy.sh <env> (5 fases; health node-side fatal + edge warn-only)"
  - "elección de docker context por entorno (prod vía context/alias SSH ${APP}-prod; test con DOCKER_CONTEXT neutralizado)"
  - "comandos de verificación del stack (stack ls / stack services / secret ls)"
  - "transición de estado del túnel inactive -> healthy al conectar el conector"
  - "regla de un solo conector (bajar el entorno de test del servidor antes de levantarlo en local)"
  - "limpieza de stack y secrets al mover un entorno entre contextos"
  - "stack deploy no remueve servicios eliminados del yml (retirar un servicio = quitarlo del yml + docker service rm manual)"
reads-before: [ops.entornos-imagen, ops.secretos, ops.exponer-tunnel]
related: [proc.arrancar]
---

# Desplegar el stack en Swarm

> **Este es el mecanismo canónico de deploy del proyecto.** En producción no se invoca
> `deploy.sh` a mano: lo conduce el comando **`/forja:deploy`** de Claude Code, que agrega el
> preflight (rama `main`, tree limpio, gates verdes, confirmación), el backup off-site y
> los dos planos de rollback. El modelo completo de release está en
> [Release por comando y CI de gates](./08_how-to-pipeline-cicd.md); este doc documenta la
> mecánica del stack que ese comando ejecuta.

Despliega la aplicación como **stack del Swarm** en dos entornos aislados (`prod` y `test`): cada uno levanta sus cinco servicios (`app`, `db`, `cloudflared`, `backup` y el job `migrate`), conecta su túnel y deja su dominio sirviendo. Ambos usan **el mismo `stack.yml`, el mismo `deploy.sh` y el mismo mecanismo de secrets y túnel**; lo único que cambia es el **docker context** de destino. El túnel que quedó `inactive` al [exponer la app por Cloudflare Tunnel](./05_how-to-exponer-cloudflare-tunnel.md) pasa aquí a `healthy` y el error 1033 desaparece.

## Norma

### Un solo `stack.yml`, un solo `deploy.sh`, el context como variable

La única diferencia entre desplegar a producción y a un entorno de pruebas es el **docker context** sobre el que opera `deploy.sh`. El mismo archivo de stack, script y mecanismo de secrets producen ambos entornos. Esto da la **paridad dev-local / prod-server**: el comando que validas en local es, byte por byte, el que corre contra el servidor.

- **`prod`** despliega en el servidor a través del context **`${APP}-prod`**. La convención del nombre está **fijada por `deploy.sh` y `scripts/release/lib.sh`** (misma convención que en [el modelo de operación](./01_explicacion-modelo-operacion.md)), y el **mismo nombre debe existir además como alias `Host` idéntico en `~/.ssh/config`**: los scripts de release hacen `ssh ${APP}-prod` directamente contra el nodo.
- **`test`** despliega en el Swarm **local**: `deploy.sh` hace `unset DOCKER_CONTEXT` deliberadamente para que un context heredado **jamás redirija un deploy de test al nodo de producción**; usa el context local activo.

Todos los comandos se ejecutan **en tu máquina local**: `deploy.sh` resuelve el docker context según el entorno y, sobre ese context, construye las imágenes y opera el Swarm.

### El flujo de `deploy.sh <env>`: cinco fases

`deploy.sh` encadena cinco fases sobre el context del entorno:

1. **Build**: construye **tres imágenes** desde el mismo `Dockerfile` vía `--target` (`runner` → app, `migrator` → migrate, `backup` → sidecar), sin registry intermedio. Con `SKIP_BUILD=1` (camino CI) exige refs prebuilt explícitas (`APP_IMAGE`/`MIGRATE_IMAGE`).
2. **Secrets**: materializa cada clave de `secrets/<env>.env` como Docker secret prefijado por el stack, **omitiendo los que ya existan** (nunca pisa un secret vivo); `SKIP_SECRETS=1` la salta en corridas estilo CI. Con o sin skip, **asevera que TODOS los secrets requeridos existen antes de tocar la base**: un secret sin bootstrapear aborta aquí, no con el esquema ya migrado.
3. **Backup pre-migración** (solo `prod`): `pg_dump -Fc` sobre el contenedor `db`, validado con `pg_restore --list`. Una `db` ausente o un dump inválido **abortan en seco**: sin punto de restore no hay migración.
4. **Stack deploy + migración gateada**: despliega desde `stack.yml` y hace *polling* del job `migrate` (`Failed`/`Rejected` abortan con logs). En el camino local de tag mutable (`:latest`) además fuerza el roll de `app`: el digest no cambia y `stack deploy` solo no reemplazaría el contenedor.
5. **Health**: la señal **fatal y autoritativa es node-side** — `docker exec` en la task de `app` y `node -e` con `fetch` a `http://127.0.0.1:8000/api/health`. La sonda del **edge público** (`https://<host-del-entorno>/api/health`) es **warn-only** porque fusiona los dominios de fallo de app, túnel y Cloudflare (`530`=cloudflared, `502`=app): un transitorio del conector nunca tumba un deploy sano.

Los números de `stack.yml` sostienen la fase 5: healthcheck de `app` con `interval: 10s`, `timeout: 3s`, `retries: 3`, `start_period: 45s`, y `update_config` con `monitor: 90s` porque el monitor **debe superar** `start_period + retries × interval = 75 s`, o el rolling marca exitosa una versión aún no declarada unhealthy y `failure_action: rollback` no dispara nunca.

> En un Swarm de un solo nodo, `docker stack deploy` avisa que no puede registrar el *digest* en un registry: es esperable y no impide el despliegue (ver [el modelo de operación](./01_explicacion-modelo-operacion.md)).

### `stack deploy` no remueve servicios eliminados del yml

`docker stack deploy` es aditivo/actualizador: crea y actualiza servicios, pero un servicio que **desaparece** de `stack.yml` **sigue corriendo** en el Swarm tras el deploy. Retirar un servicio del stack son dos gestos, no uno: quitarlo del yml **y** `docker service rm ${STACK}_<servicio>` en cada entorno donde estuvo desplegado. Verificado al retirar un sidecar: el yml ya no lo declaraba y el servicio siguió vivo hasta el `service rm` manual.

### Secrets prefijados por stack y aislamiento entre entornos

`deploy.sh` materializa cada clave de `secrets/<env>.env` como un Docker secret **prefijado por el nombre del stack** (`${STACK}_<clave-secret>`). Como el prefijo difiere por entorno, dos entornos que parten del **mismo `stack.yml`** montan secrets distintos. Fija valores **distintos por entorno desde el principio**: como el script nunca pisa un secret existente, el valor con que se crea es el que queda hasta una rotación explícita (ver [Secretos](./07_referencia-secretos.md)). El patrón `secrets/*.env` está cubierto por `.gitignore`; trátalos como secretos reales.

### Regla del único conector

Un túnel solo puede servirse desde **un lugar a la vez**. Si el `cloudflared` del servidor y el de tu máquina intentan servir el mismo túnel, las dos conexiones se pelean y el tráfico se parte. Antes de levantar un entorno en un context nuevo, **bájalo del context anterior** (stack y secrets incluidos). Mover un entorno entre contextos no es solo `stack deploy` en el destino: es **limpieza en el origen** primero.

### Precondiciones

Antes de desplegar necesitas:

- El servidor [aprovisionado](./03_how-to-aprovisionar-servidor.md) y [endurecido](./04_how-to-endurecer-acceso.md): Swarm de un nodo (manager), usuario `deploy` en el grupo `docker`, firewall dejando entrar solo SSH.
- Los túneles [aprovisionados por API](./05_how-to-exponer-cloudflare-tunnel.md) con su ingress, su CNAME y su token en `secrets/<env>.env` (clave del token del túnel).
- Para `prod`: el docker context **`${APP}-prod`** apuntando al servidor por SSH, **y** el alias `Host ${APP}-prod` en `~/.ssh/config` (los scripts de release hacen `ssh` a ese mismo nombre):
  ```bash
  docker context create ${APP}-prod --docker host=ssh://deploy@<IP>
  ```
- Para `test`: un **Swarm local** ya inicializado (`docker swarm init`); no hay variable de context que exportar (`deploy.sh` neutraliza `DOCKER_CONTEXT`).
- Los archivos del proyecto en la raíz del repositorio (`src/`, `Dockerfile`, `stack.yml`, `deploy.sh`) y un `secrets/<env>.env` con **todas** las claves que el stack exige.
- Competencia básica con Docker, `docker stack`, `docker secret` y `curl`.

## Camino verificado

Validado desplegando los dos entornos reales: stack de producción en el servidor (context `${APP}-prod`) y stack de pruebas en el Swarm local.

### Paso 1 — Desplegar producción

```bash
./deploy.sh prod
```

El script encadena las cinco fases de la Norma sobre el context `${APP}-prod` y termina validando la **salud node-side** contra `/api/health` (edge warn-only).

### Paso 2 — Verificar producción

Lista el stack y sus servicios:

```bash
docker -c ${APP}-prod stack ls
docker -c ${APP}-prod stack services ${STACK}
```

El stack debe aparecer con **cinco servicios**, cada uno con 1 réplica:

```
NAME                  MODE            REPLICAS
${STACK}_app          replicated      1/1
${STACK}_backup       replicated      1/1
${STACK}_cloudflared  replicated      1/1
${STACK}_db           replicated      1/1
${STACK}_migrate      replicated job  0/1 (1/1 completed)
```

`migrate` es un *replicated job*: corre una vez; `0/1 (1/1 completed)` es su estado terminal esperado, no un fallo.

Sonda el edge:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://<host-de-prod>/api/health
```

Debe responder `200` cuando el conector del túnel se establece (los `502`/`530` iniciales son el transitorio esperado; el deploy ya validó la salud node-side).

Comprueba el estado del túnel desde la API de Cloudflare (credenciales del aprovisionamiento cargadas):

```bash
source ~/.cf_provision.env
curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel?is_deleted=false" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  | jq -r '.result[] | "\(.name)\t\(.status)"'
```

El túnel de producción debe figurar ahora como `healthy` (con sus conexiones activas), no ya como `inactive`. Con eso, el error 1033 queda resuelto.

### Paso 3 — Desplegar y verificar pruebas

Repite el despliegue para `test`, esta vez contra el **Swarm local**:

```bash
./deploy.sh test
```

> **Antes de levantar `test` en local, bájalo del servidor** (regla del único conector). Retíralo del servidor primero, stack y secrets incluidos:
> ```bash
> docker -c ${APP}-prod stack rm ${APP}_test
> docker -c ${APP}-prod secret ls --format '{{.Name}}' | grep "^${APP}_test_" \
>   | xargs -n1 docker -c ${APP}-prod secret rm
> ```

El flujo es análogo, sin la fase de backup (solo `prod`), y termina con el health node-side y la sonda warn-only sobre `https://<host-de-test>/api/health`. Verifica con `docker stack services ${APP}_test`: los mismos cinco servicios, con `migrate` en `0/1 (1/1 completed)`.

### Paso 4 — Verificación final

Confirma que cada entorno quedó arriba en **su** context:

```bash
docker -c ${APP}-prod stack ls
docker -c ${APP}-prod secret ls
```

`stack ls` debe mostrar **solo** el stack de producción (5 servicios). `secret ls` debe listar sus secrets prefijados por stack (los 12 que exige `stack.yml`). Repite ambos comandos sin `-c` (context local) para el stack de pruebas.

Por último, vuelve a listar los túneles desde la API de Cloudflare: tanto el de producción como el de pruebas deben estar en `healthy`. La cadena está cerrada: ambos dominios sirven, cada uno por su túnel y desde su entorno, sin un solo puerto entrante abierto en el servidor.

---

## Lo que sigue

Con los dos stacks desplegados y sirviendo, el aprovisionamiento queda completo de extremo a extremo: servidor en Swarm, acceso cerrado, túneles conectados y aplicación publicada en `prod` y `test`. El porqué del modelo —cómo el stack reúne servicios, red y secrets en una unidad— está en [el modelo de operación](./01_explicacion-modelo-operacion.md). Para arrancar un proyecto nuevo de cero, ver [Arrancar un proyecto nuevo](../proceso/04_how-to-arrancar-proyecto-nuevo.md).
