---
id: ops.modelo-operacion
titulo: Modelo de operación
tipo: explicacion
tier: 3
audience: both
resumen: Catálogo de infraestructura de producción, topología de la petición y decisiones del modelo de despliegue sobre un nodo único.
provides:
  - "catálogo de infraestructura de producción"
  - "VPS de un solo nodo"
  - "Docker Engine"
  - "Docker Swarm orquestador de nodo único"
  - "Docker Stack como unidad"
  - "gestión remota vía docker context sobre SSH"
  - "GHCR como registry de imagen (entrada del dial: el build deja de ocurrir en la máquina que despliega)"
  - "imagen como unidad inmutable con output standalone"
  - "sin puertos entrantes y egress por 7844"
  - "red overlay backend con resolución por nombre de servicio"
  - "topología de tres servicios"
  - "liveness vs readiness probe"
  - "start-first"
  - "failure_action rollback"
  - "presupuesto de conexiones a Postgres"
  - "Full SSL"
  - "build-on-node sin registry"
  - "token-file para cloudflared"
  - "un túnel un conector"
  - "paridad dev-local prod-server vía docker context"
  - "raft del Swarm como ubicación de secrets"
  - "tradeoff del raft cifrado sin --autolock (la mitigación real es el control de acceso al host y al proveedor, no la unlock-key)"
reads-before: [fund.principios]
related: [fund.principios]
---

# Modelo de operación

La planta de producción como doctrina portable: qué pieza cumple cada función, cómo
viaja una petición hasta el proceso, y por qué el despliegue se resuelve sobre un
**único nodo** con Docker Swarm. La regla rectora de inmutabilidad de la que se
desprende casi todo lo que sigue vive en
[Principios del proyecto](../fundamentos/01_explicacion-principios.md).

**Norma** fija lo que se replica igual en cualquier proyecto nuevo. **Camino verificado**
recoge el procedimiento ya ejecutado y depurado sobre un servidor real, con las decisiones
que solo se entienden cuando el builder y el nodo coinciden.

---

## Norma

### Catálogo de infraestructura de producción

Una pieza por función. Cada fila es la elección única para su área.

| Área | Elección (única) | Para qué |
|---|---|---|
| Servidor | VPS de un solo nodo (`<VPS>`) | Host único de producción |
| Motor de contenedores | Docker Engine (repo APT oficial, versión pineada + `apt-mark hold`) | Runtime del nodo ([Aprovisionar el servidor](./03_how-to-aprovisionar-servidor.md)) |
| Orquestador | Docker Swarm (nodo único) | Scheduling, secrets cifrados, red overlay, rolling update + rollback |
| Despliegue | Docker Stack | Despliega el `stack.yml` como una unidad |
| Gestión remota | `docker context` (sobre SSH) | Operar el swarm desde local/CI sin copiar archivos al server |
| Ingreso | Cloudflare Tunnel (`cloudflared`), remotely-managed por token | Entrada sin puertos abiertos; TLS lo termina el borde de Cloudflare |
| DNS / WAF / CDN | Cloudflare (zona `${APP}.<dominio>`) | CNAME al túnel; WAF y cache en el borde |
| Registro de imágenes | — (build-on-node vía docker context; sin registry) | Con un solo nodo, la imagen se construye donde corre. GHCR entra por el dial si el build deja de ocurrir en la máquina que despliega |
| CI | GitHub Actions (solo gates) | Verificación en PR (check/integration/contract/migrations); el ship es el comando `/forja:deploy` |
| Backups retenidos | sidecar `backup` del stack -> Storage Box (SFTP) | Dump diario validado, retención 7 local y off-site; restic es dial ([Backups](./09_how-to-backups.md)) |
| Backup pre-migración | `pg_dump -Fc` validado, local + Storage Box | Punto de restore inmediato en cada deploy a prod |
| Hardening | SSH key-only, firewall, fail2ban | Superficie de ataque mínima |

### Las decisiones del modelo

- **Un solo desplegable, un solo orquestador, un solo nodo.** Docker Swarm sobre un VPS
  es el mínimo viable que da rolling updates sin downtime, secrets cifrados y rollback
  —lo que importa de producción— sin la carga operativa de Kubernetes. Kubernetes (k3s) y
  el multi-nodo son escalaciones deliberadas del dial, no el punto de partida.

- **Sin puertos entrantes.** `cloudflared` abre una conexión **saliente** a Cloudflare; no
  se expone ningún puerto de la app a Internet. El único ingreso es por el túnel. El
  servidor solo necesita egress al borde de Cloudflare (puerto `7844`) y SSH entrante para
  operación.

- **La imagen es la unidad inmutable.** Se construye una vez —imagen multi-stage con
  usuario sin privilegios—, se tagea por **SHA del
  commit** (nunca `latest`) y se promueve tal cual; no se reconstruye por entorno. Config y
  secrets se inyectan en runtime: el módulo de config de la app lee `/run/secrets`, montados por
  Swarm; nada se hornea en la imagen. Detalle en
  [Entornos e imagen Docker](./02_referencia-entornos-e-imagen.md).

### El camino de una petición

Tres servicios en una red overlay, un túnel saliente sin puertos abiertos, `db` anclada
al manager y un healthcheck que gobierna el rollback.

```
Internet
   │  HTTPS  (TLS termina en el borde de Cloudflare; WAF + CDN se aplican aqui)
   ▼
Cloudflare edge ──── DNS: ${APP}.<dominio>  CNAME  <tunnel-id>.cfargotunnel.com  (proxied)
   │  conexion SALIENTE y cifrada (la inicia cloudflared; NO hay puertos entrantes)
   ▼
┌─ VPS — Docker Swarm (nodo unico) ──────────────────────────────────────────┐
│                                                                            │
│   red overlay:  ${STACK}_backend                                           │
│                                                                            │
│     cloudflared ──── http://app:8000 ────▶  app  (la app, N replicas)      │
│                                               │                            │
│                                               └── postgresql ──▶  db        │
│                                          (1 replica, en el manager, volumen persistente) │
│                                                                            │
│   Docker secrets montados en /run/secrets/  (cifrados en reposo y transito)│
└────────────────────────────────────────────────────────────────────────────┘
```

### El stack agrupa servicios, red y secrets en una unidad

`docker stack deploy -c stack.yml ${STACK}` aplica un **conjunto declarado** de
piezas interdependientes: los servicios `app`, `db` y `cloudflared`, la red overlay que
los conecta y los secrets que cada uno monta. La red, los volúmenes y los secrets quedan
prefijados con el nombre del stack (`${STACK}_backend`, `${STACK}_pgdata`, etc.), lo que
**aisla un entorno de otro**. Desplegar materializa todo de una vez y coherente: ambos
servicios nacen en la misma red, encuentran sus secrets en su sitio, y el Swarm reconcilia
el estado declarado contra el real sin orden de arranque manual.

**El nombre del servicio es el nombre de red.** `cloudflared` y `app` se resuelven entre
sí por su nombre de servicio en la overlay (DNS interno del swarm). Por eso el ingress del
túnel apunta a `http://app:8000` y no a `localhost`: son contenedores distintos. El
servicio `app` corre el servidor de la aplicación, que escucha en
el puerto interno del contrato (`runtime.port` de `.forja.json`, el mismo `PORT` que fija
`stack.yml`); ese único proceso sirve la app completa, porque es un único desplegable. El modelo de exposición por
túnel se desarrolla en [Exponer la app por Cloudflare Tunnel](./05_how-to-exponer-cloudflare-tunnel.md).

**`db` corre en el manager, con volumen y una sola réplica.** La persistencia no se
replica a mano en swarm: una única instancia con su volumen `pgdata`, anclada al nodo
manager. La versión mayor de PostgreSQL se fija antes de crear el volumen de producción y
no se cambia en caliente.

### Healthcheck: liveness y readiness gobiernan el rollback

La app expone el endpoint de health del contrato (`runtime.healthcheckPath` de
`.forja.json`, default `/api/health`) y de ese check depende el rollback
automático del deploy (ver [Pipeline de deploy y CI/CD](./08_how-to-pipeline-cicd.md)). El
endpoint distingue dos preguntas:

- **Liveness** — ¿el proceso responde? El server de la app está en pie. Es barato y no toca
  dependencias; es la señal que mira el Swarm para reiniciar una task colgada.
- **Readiness** — ¿el proceso puede servir tráfico real? Además de estar en pie, ejecuta
  un `SELECT 1` al pool de `db` con timeout corto (≈1s). Distingue "arrancó" de "está
  listo". Es la readiness la que gobierna la promoción de la réplica nueva bajo
  `start-first` y, por tanto, el `failure_action: rollback`: una app en pie pero con
  Postgres inalcanzable falla la readiness y dispara el rollback, en vez de dejar prod
  "verde" pero roto.

El bloque `healthcheck` del servicio `app` en el compose es el que gobierna el rollback:

```yaml
healthcheck:
  # readiness: 200 solo si el SELECT 1 al pool responde dentro del timeout;
  # el puerto y el path salen del contrato (runtime.port / healthcheckPath)
  test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:<port><path> || curl -fsS http://127.0.0.1:<port><path>"]
  interval: 10s
  timeout: 3s
  retries: 3
  start_period: 45s   # cubre el cold start del server de la app
```

**`start-first`** es el orden de actualización: el Swarm arranca la réplica nueva y no baja
la vieja hasta que la nueva pasa el healthcheck. Así siempre hay al menos una réplica
atendiendo y el dominio no deja de responder durante el cambio; el costo es convivir un
instante con ambas versiones —razonable para una app web sin estado—. El `start_period`
generoso evita un rollback en falso por marcar unhealthy una task que aún calienta; la
ventana de observación de `update_config.monitor` debe **exceder** el `start_period` para
que promover o revertir se decida sobre una réplica ya lista.

### Presupuesto de conexiones a Postgres

Cada réplica de `app` corre el server standalone con su **propio** pool de `pg`; los pools
no se comparten entre réplicas. El techo del pool se fija explícito en la config —`max`
(p. ej. 5–10 por réplica), junto con `idleTimeoutMillis` y `connectionTimeoutMillis`— en
vez de quedar en el default implícito de la librería.

El invariante de capacidad a respetar al escalar es:

```
replicas × pool.max  +  conexiones del one-shot `migrate`  +  margen  <  max_connections
```

Con 2 réplicas y `max = 10` son 20 conexiones de la app; el servicio one-shot `migrate`
abre las suyas en paralelo a la app viva durante la ventana de migración, así que **cuenta
en el presupuesto**. El runner de `migrate` usa `allowExitOnIdle` para cerrar su pool al
terminar y un `application_name` distinto al de la app, lo que lo hace ubicable en la vista
de actividad de la base. Mientras el cálculo sobre `max_connections` tenga holgura, no hace
falta un pooler externo; acercarse al techo es el disparador de la entrada "Límite de
conexiones de PostgreSQL" del dial.

### Secrets inmutables y prefijados por stack

Cada secret combina stack y clave (`${STACK}_<clave-secret>`). El prefijo **aisla los
entornos**: dos entornos comparten `stack.yml` y `deploy.sh` —solo cambia el docker
context—, pero sus secrets tienen nombres distintos y por tanto son objetos diferentes con
valores diferentes, montados cada uno en su stack. El Swarm trata a los secrets como
**inmutables por diseño**: no se editan, se reemplazan. Rotar un secreto es un acto
deliberado (eliminar el viejo y volver a desplegar), no efecto colateral de re-ejecutar el
script; el deploy nunca pisa un secret existente, lo que vuelve el despliegue seguro de
repetir. Su raíz física es el **raft del Swarm**, cifrado en el nodo manager. Ciclo de vida
completo y contrato de nombre en [Secretos](./07_referencia-secretos.md).

**Tradeoff aceptado: raft cifrado en reposo sin `--autolock`.** El raft está cifrado, pero
la clave que lo descifra vive **en disco** junto al nodo: sin `--autolock`, quien obtenga
una copia del disco del VPS puede leer los secrets de producción. Activar `--autolock`
cerraría ese hueco, pero obliga a **reingresar la unlock-key a mano en cada reinicio del
daemon Docker** —choca con el reboot desatendido tras un parche de kernel y dejaría los
servicios caídos esperando intervención manual—. La decisión consciente es **no activar
`--autolock`**: la mitigación real del riesgo no es la unlock-key sino el **control de
acceso al host y al proveedor** (SSH key-only, firewall, acceso restringido al panel del
proveedor y a los snapshots de disco). Queda escrito como tradeoff, no como hueco
silencioso: la pérdida del nodo está cubierta porque los secrets se recrean desde su fuente
off-site; el robo o copia del disco se contiene por acceso, no por cifrado autolock.

### `cloudflared` recibe su token con `--token-file`

El token se monta como **Docker secret** y se entrega con
`command: tunnel run --token-file /run/secrets/<clave-secret>`, no como variable de
entorno. Dos razones encadenadas. Seguridad: un secreto en variable de entorno queda
visible en la definición del servicio, en `docker inspect` y en cualquier volcado del
entorno del proceso; montado como secret, el token vive solo como archivo dentro del
contenedor. Práctica: la imagen oficial de `cloudflared` **no trae shell**, así que no se
puede envolver el arranque en un script que lea el archivo y exporte una variable. La
imagen resuelve el caso con `--token-file` (y la variable `$TUNNEL_TOKEN_FILE`): el binario
lee el token directo del archivo del secret, sin shell.

### Paridad dev-local y prod-server: mismo mecanismo, distinto context

Los entornos son **el mismo despliegue** en dos lugares: comparten `stack.yml`,
`deploy.sh` y el mecanismo de secrets y tunel; solo cambia el **docker context** de
destino. `deploy.sh` lo resuelve por entorno: producción apunta al servidor (context
`${APP}-prod`, por SSH) y el entorno local a un Swarm de desarrollo (context
`<contexto-local>`). Como el mecanismo es idéntico, lo que funciona en local funciona en el
servidor: el entorno de desarrollo apunta a otro nodo, no es una maqueta. El SSL de
Cloudflare va en **Full**; la app habla HTTP plano con `cloudflared` por dentro.

---

## Camino verificado

### El modelo de producción es build-on-node + 3 servicios

El stack de **producción** son **tres servicios** (`app`, `db`, `cloudflared`) desplegados
por `docker stack deploy`, con la imagen **construida en el propio nodo destino** vía el
docker context del entorno, sin registry intermedio. El ship lo conduce el comando
`/forja:deploy` desde la máquina del operador (ver [Release por comando](./08_how-to-pipeline-cicd.md)).

Cada Swarm del proyecto tiene un solo nodo. Un registry resuelve distribuir la misma imagen
a varios nodos; con un único nodo la imagen construida es exactamente la que ese nodo corre,
así que un registry resolvería un problema inexistente. Por eso `docker stack deploy` emite
una advertencia: no encuentra un registry donde registrar el *digest*. Es un aviso, no un
error: con un solo nodo no hay nada que reconciliar y el stack corre igual.

### GHCR: entrada del dial, no default

El razonamiento anterior vale mientras builder y nodo coincidan. Se rompe cuando el build
ocurre en un runner separado —el caso del deploy vía CI—: ahí la imagen debe viajar por un
registry (GHCR, tageada por SHA del commit, `pull` con `--with-registry-auth`). Ese modelo
**se implementó y funcionó** (queda en el historial de git como riel recuperable), pero es
una **escalación del dial** cuyo disparador es que el deploy vuelva al CI o aparezca el
multi-nodo; su costo probado está documentado en la
[lección del pipeline por tag](./08_how-to-pipeline-cicd.md#lección-verificada-el-pipeline-por-tag).

### Un túnel, un conector

Un túnel de Cloudflare admite **un solo conector a la vez**: dos `cloudflared` que arranquen
con el mismo token sirven el mismo túnel, las conexiones compiten y el tráfico se parte de
forma impredecible. De ahí que los túneles estén **segmentados**: `prod` tiene el suyo
(servido desde el servidor) y **cada developer tiene el suyo para test** (`${APP}-test-<dev>`,
servido desde su máquina local, con su token en su `secrets/test.env`). Así el conector de
cada túnel vive en un solo lugar por diseño y nadie compite por el mismo recurso. Si alguna
vez hay que **mover un mismo entorno entre máquinas** (p. ej. bajar un test que quedó
corriendo en otro context), primero se retira del origen —stack (`docker -c <ctx> stack rm
${STACK}`) y secrets— para dejar el túnel libre antes de levantarlo en el destino. El
procedimiento ejecutado está en [Desplegar el stack en Swarm](./06_how-to-desplegar-swarm.md).

### Subdominios de un solo nivel

Los hostnames del proyecto (`${APP}.<dominio>`, `<dev>-${APP}.<dominio>`) son labels de un
solo nivel y los cubre el Universal SSL de Cloudflare. Un subdominio multinivel
(`x.y.<dominio>`) exigiría un Advanced Certificate; se evita. El label per-developer de test
(`aguerodev-${APP}`, `dev-${APP}`, …) sigue siendo una sola etiqueta con guiones, así que
cae dentro del comodín gratuito.

### Logs del stack acotados en tamaño

El nodo es único: la `app` y PostgreSQL comparten el mismo disco. Los logs salen como JSON
estructurado a stdout y el driver de Docker los persiste en el host. Sin un tope, el driver
`json-file` por defecto los acumula sin límite hasta llenar el disco; y cuando el disco se
llena no solo cae la `app`: PostgreSQL deja de poder escribir y la base cae con él. Por eso
cada servicio del stack declara una política de logging acotada —`max-size` por archivo y
`max-file` rotados— para que el espacio que consumen los logs tenga un techo conocido. Es
un guardarrail de disponibilidad barato: la retención local cubre el diagnóstico inmediato,
y cuando haga falta buscar logs históricos más allá de lo que cabe local, el siguiente
escalón del dial es la agregación externa —decisión separada del salto a tracing—.

El tope de logs acota una vía de llenado, pero **no** observa el disco. Por eso el
**monitoreo base de recursos del host** (disco, inodos, memoria, CPU) es una
**precondición operacional desde el día 0**, no una aspiración para "cuando crezca": sin una
medición establecida desde el primer arranque, el operador se entera del problema (disco
lleno tira `app` y PostgreSQL) cuando los usuarios ya lo sufren. El mínimo obligatorio
—timer + script + **webhook** de alerta; escribir al journal no es una alerta— y su frontera
con el dial de observabilidad se definen una sola vez en
[Seguridad operativa](./10_referencia-seguridad-operativa.md#monitoreo-mínimo-obligatorio-vs-dial).

---

## Puntos clave

- El stack es la unidad de despliegue: un `stack.yml` reúne servicios, red overlay y
  secrets, y un comando los materializa coherentes; por eso `cloudflared` alcanza a `app`
  por nombre de servicio.
- Sin puertos entrantes: `cloudflared` abre una conexión saliente (egress `7844`); el único
  ingreso es el túnel y el único entrante operativo es SSH.
- La imagen es inmutable, tageada por SHA; config y secrets se inyectan en runtime desde
  `/run/secrets`.
- `start-first` actualiza sin caída; el healthcheck (liveness vivo, readiness con `SELECT 1`)
  decide la promoción y gobierna `failure_action: rollback`.
- Con un solo nodo, el modelo canónico es build-on-node + 3 servicios: la imagen se
  construye donde corre. GHCR es la entrada del dial para cuando el build deje de ocurrir
  en la máquina que despliega (deploy vía CI o multi-nodo).
- Un túnel admite un solo conector: por eso `prod` y el test de cada developer son túneles
  separados; mover un mismo entorno entre máquinas exige bajarlo del origen primero.
- Los logs van acotados por servicio: en un nodo único, logs sin tope llenan el disco y
  tiran la `app` y PostgreSQL.
