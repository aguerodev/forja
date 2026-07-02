---
id: ops.aprovisionar
titulo: Aprovisionar el servidor
tipo: how-to
tier: 3
audience: both
resumen: De un VPS recién creado a un nodo manager de Swarm operativo, con la referencia verificada de aprovisionamiento y el runbook de recuperación.
provides:
  - "secuencia de aprovisionamiento"
  - "DEBIAN_FRONTEND/NEEDRESTART_SUSPEND"
  - "reboot tras kernel"
  - "unattended-upgrades"
  - "usuario deploy disabled-password"
  - "docker swarm init"
  - "referencia verificada de aprovisionamiento"
  - "runbook de recuperación ante desastre"
  - "precondición de secrets off-site"
  - "Fase 0 antes del primer boot (cloud-init user_data.yaml: alta de deploy, pubkey y hardening base antes de que SSH abra)"
  - "firewall de borde del proveedor (capa-1 deny-all salvo 22/tcp en v4 y v6 por separado; fuera del host, no saltable por docker -p)"
  - "aprovisionamiento como artefacto ejecutable (provision.sh idempotente + verify.sh post-condiciones + user_data.yaml; el script es la verdad)"
  - "swapfile modesto (2G + vm.swappiness=10 como red de seguridad contra el OOM killer)"
  - "journald persistente y capeado (Storage=persistent + SystemMaxUse; base de fail2ban backend=systemd tras reboot)"
  - "auto-reboot del parcheo desatendido (Automatic-Reboot 04:00 solo si existe /var/run/reboot-required; sin él, el kernel parcheado no se activa)"
  - "Docker pineado por versión (repo APT oficial + apt-mark hold; nunca curl|sh a latest flotante)"
  - "daemon.json de rotación de logs escrito antes de levantar servicios (json-file max-size/max-file)"
  - "backups del proveedor (snapshots de disco habilitados en Fase 0, ~+20%; atajo de RTO que cubre pgdata y el raft, complemento del dump off-site)"
  - "golden snapshot del base endurecido (atajo de RTO: rebuild desde imagen en minutos; no respalda datos)"
reads-before: [ops.modelo-operacion]
related: []
---

# Aprovisionar el servidor

Esta guía lleva un VPS recién creado, con acceso `root`, hasta un nodo Docker Swarm operativo (manager) con un usuario `deploy` listo para desplegar sin `sudo`.

Asume que ya tenes:

- Un VPS creado y su IP pública.
- Acceso SSH como `root` (clave o contraseña inicial del proveedor).
- Competencia básica con la línea de comandos de Linux y SSH.

Todos los comandos se ejecutan **como `root`**, salvo donde se indique.

> El flujo fue validado sobre Ubuntu LTS, pero la secuencia `apt` es idéntica en cualquier derivado Debian (`ID_LIKE=debian`).

Por qué el nodo se opera así: [Modelo de operación](./01_explicacion-modelo-operacion.md).

> **Fuente de verdad ejecutable.** El aprovisionamiento se codifica como artefacto versionado, no como prosa: `operaciones/provision.sh` (idempotente, `set -euo pipefail`) ejecuta la secuencia, `operaciones/verify.sh` valida las post-condiciones (sale ≠0 si algo falla) y `operaciones/user_data.yaml` (cloud-init) hace el bootstrap del primer boot. **Los scripts son la verdad; este documento explica el PORQUÉ de cada decisión.** Un nodo nuevo se levanta corriendo el script, no copiando comandos a mano. Si un comando del doc y el script difieren, gana el script.

---

## Norma

Procedimiento portable y el porqué de cada decisión, independiente de proveedor o host concreto.

### Secuencia de aprovisionamiento

El orden es deliberado y cada paso habilita al siguiente:

0. **Fase 0 — antes del primer boot** (en la consola/API del proveedor): firewall de borde `deny-all` salvo `22/tcp` (v4 **y** v6), server con clave SSH adjunta y **sin** password de root, backups del proveedor habilitados, y `cloud-init` que inyecta el hardening base antes de que SSH abra.
1. **Actualizar el SO a fondo** (`apt full-upgrade`) y fijar el estado base: timezone UTC + NTP, swap, journald persistente.
2. **Reiniciar si se instaló un kernel nuevo** (solo si existe el flag de reboot pendiente).
3. **Activar el auto-parcheo con reinicio automático en ventana** (`unattended-upgrades` + `Automatic-Reboot`).
4. **Crear el usuario `deploy`** con la contraseña bloqueada.
5. **Configurar `daemon.json` ANTES de levantar servicios** (rotación de logs) e instalar Docker **pineado** a una versión.
6. **Dar permisos de Docker a `deploy`**.
7. **Inicializar el Swarm** (`docker swarm init --listen-addr 127.0.0.1`, con guard idempotente).
8. **Dejar monitoreo base del host** (timer + script + webhook) y correr `verify.sh`.

### Por qué una Fase 0 antes del primer boot

El período entre "server arriba" y "acceso endurecido" es la ventana más expuesta: IP pública, todos los puertos accesibles y, si el proveedor mandó una contraseña de root por mail, autenticación por password abierta. Esa ventana se cierra **antes de encender**, no después, y casi todo es un checkbox en la consola del proveedor (cero operación extra). El detalle ejecutable vive en `provision.sh` y `user_data.yaml`; el porqué:

- **Firewall de borde `deny-all` salvo `22/tcp`.** Es una capa-1 independiente del SO: filtra en la red del proveedor, **antes** de que el paquete llegue a la VPS, y no es saltable por `docker run -p` (el bypass de Docker a `ufw` está documentado en [Endurecer el acceso](./04_how-to-endurecer-acceso.md)). En el proveedor las reglas v4 y v6 son **separadas**: abrir solo `0.0.0.0/0` deja `::/0` abierto, o al revés te bloquea por IPv6 con el firewall viéndose limpio. Hay que abrir `22/tcp` para **ambas** familias (idealmente acotado al CIDR del operador). Egress permitido. Esto **no reemplaza** a `ufw`; es la red que Docker no puede tocar. Cuando lo gestiona un agente vía la API, ese firewall se aplica **como código** con `hcloud firewall replace-rules <fw> --rules-file operaciones/firewall-rules.json` (una operación atómica desde el archivo versionado), **no** con `add-rule` incremental ni "creado a mano en la consola" — el incremental acumula drift y abre puertos sin cerrarlos.
- **Clave SSH adjunta y sin password de root.** Si la pubkey del operador se inyecta al crear el server y root nace sin contraseña, no hay mail con password ni ventana de password-auth desde el minuto cero.
- **Backups del proveedor (activados por defecto).** El runbook de DR marca `pgdata` y el raft del Swarm como "no respaldados"; los backups automáticos del proveedor (snapshots diarios rotativos, **~+20% del costo del server**) cubren exactamente esos huecos y bajan el RTO a un *rebuild-from-image* en minutos. **Son parte del protocolo: se habilitan al crear el server y se asume el +20%.** Es **complemento** del dump off-site, no reemplazo: el dump diario del sidecar en el Storage Box sigue siendo el RPO de negocio y la única copia fuera del nodo; el backup del proveedor es el atajo de RTO. Un snapshot manual antes de cada cambio riesgoso es una capa adicional sobre el backup automático. Cuando un agente ejecuta esta fase vía la API, `--enable-backup` viaja junto a dos guardarraíles ejecutables: el **confirmar-o-crear por label** (`hcloud server list -l managed-by=agent,...` antes de `create`; `>1 match` = parar) que vuelve idempotente un `create` que no lo es, y `hcloud server enable-protection <id> delete rebuild`, que impide borrar o reconstruir el server **incluso con un token Read&Write** hasta que un humano quita la protección en la consola. El detalle completo de la gestión por agente vía la API —matriz de capacidades, dos tokens segregados y wrapper choke-point— vive en [Gestionar la infraestructura vía API](./12_how-to-gestionar-infra-via-api.md).
- **Defaults de plantilla.** Para que el aprovisionamiento sea reutilizable sin re-decidir cada vez, la plantilla fija un default explícito y documentado de: **tipo de server** (p. ej. ARM compartido para una agencia chica, con su tradeoff de costo/rendimiento), **location** (afecta latencia y egress del túnel) y la **decisión dual-stack vs IPv4-only** — el Primary IPv4 es un recurso **facturable aparte**, así que la plantilla elige conscientemente entre pagar IPv4 o ir IPv6-only.
- **`cloud-init` (`user_data.yaml`).** Codifica el alta de `deploy`, la inyección de la pubkey y el hardening base (`PermitRootLogin no`, `PasswordAuthentication no`) para que corran en el **primer boot, antes de que SSH abra**. Es la expresión real de "cattle, no pet": guardarrailes ejecutables en vez de pasos manuales propensos a error. El camino manual de este doc queda como fallback y explicación del porqué.

### Por qué las variables `apt` no interactivas

Antes del `full-upgrade` se exportan dos variables:

| Variable | Valor | Efecto |
|---|---|---|
| `DEBIAN_FRONTEND` | `noninteractive` | Desactiva los diálogos interactivos de `debconf`. |
| `NEEDRESTART_SUSPEND` | `1` | Suspende el menú a pantalla completa de `needrestart`, que de otro modo cuelga la sesión SSH no interactiva. |

Exportarlas **antes** del `full-upgrade` evita que ese menú congele la sesión SSH.

### Por qué `full-upgrade` y no `upgrade`

En el parcheo inicial se usa `apt full-upgrade -y`, no `apt upgrade -y`. `apt upgrade` nunca instala ni remueve paquetes para resolver dependencias, así que **retiene** (held back) cualquier actualización que arrastre una dependencia nueva — justo lo que pasa con las transiciones del meta-paquete del kernel (`linux-generic`) y con parches de seguridad que traen dependencias. En un host limpio que se quiere **totalmente al día de entrada**, eso deja agujeros. `full-upgrade` resuelve esas transiciones. En rutina, `unattended-upgrades` mantiene solo los parches de seguridad, donde el modo conservador está bien.

### Por qué timezone UTC y NTP (timesyncd, no chrony)

Todo el modelo descansa en un reloj correcto: los timers de `apt` y el backup diario del sidecar (que define el RPO ~24h), y el `findtime`/`bantime` de `fail2ban`. Con drift, esas ventanas se corren en silencio, sin error visible. Se fija `timedatectl set-timezone UTC` (convención: UTC en el servidor, el operador convierte) y se confirma `NTPSynchronized=yes`. **No se instala `chrony`**: `systemd-timesyncd` ya viene en Ubuntu LTS y alcanza para un nodo único — meter `chrony` violaría "una herramienta por área" y "robusto-no-es-máximo".

### Por qué swap modesto

Las VPS chicas nacen **sin swap**. En este nodo único conviven el manager de Swarm, PostgreSQL + su volumen y la app. Sin swap, un pico de memoria no degrada con paginado: dispara el **OOM killer**, que mata el proceso más grande (Postgres o Node) de forma abrupta, en el único nodo que también tiene los datos. Un swapfile de **2G** con `vm.swappiness=10` (swap como red de seguridad, no uso rutinario) es el seguro más barato contra ese modo de fallo.

### Por qué journald persistente y capeado

`fail2ban` usa `backend=systemd`: lee los intentos de SSH del journal. Si el journal es **volátil**, tras un reboot pierde el historial de bans y la ventana `findtime` queda ciega. Y un journal **sin cota** compite por disco con los logs de Docker, que sí están capeados. Se fija `Storage=persistent` y un techo (`SystemMaxUse`, p. ej. 500M) para que el journal herede el mismo dial de disco que ya se aplica a Docker.

### Por qué el auto-parcheo reinicia solo

Configurar `unattended-upgrades` sin reinicio automático deja el control **inerte para la clase de vulnerabilidad más grave**: el kernel. Como explica la sección del reboot, un parche de kernel solo pasa de "instalado" a "activo" al reiniciar. Sin auto-reboot, cada futuro parche de kernel se instala en disco y el nodo sigue corriendo el kernel viejo **vulnerable** indefinidamente. Se setea `Automatic-Reboot "true"` con `Automatic-Reboot-Time "04:00"`: reinicia **solo** si existe `/var/run/reboot-required`, en ventana de bajo tráfico. Para un nodo único que es SPOF, el dial "robusto-no-es-máximo" justifica el corte de ~1 min: el servicio vuelve solo (Swarm + restart policy + túnel saliente reconectan).

### Por qué hay que reiniciar tras actualizar el kernel

Cuando la actualización toca el kernel, el sistema sigue corriendo el kernel viejo hasta que reinicias.

**El malentendido.** `apt upgrade` actualiza **paquetes en disco**. Para casi todo el software basta: la próxima ejecución corre la versión nueva. El kernel es la excepción: no es un programa que se "vuelve a ejecutar", es código **cargado en memoria** desde el arranque. Cuando `apt` instala `linux-image-...-generic`, escribe el kernel nuevo en disco y actualiza `/boot/vmlinuz`, pero la máquina sigue ejecutando en RAM el kernel cargado al encender. El nuevo solo entra en el próximo arranque.

**Por qué importa para la seguridad.** Los parches que corrigen vulnerabilidades **del propio kernel** no protegen mientras el kernel viejo siga en memoria: el código vulnerable es justo el que corre. El parche queda instalado en disco y el agujero abierto en ejecución. El reinicio es el momento en que esos parches pasan de "instalados" a "activos".

**Cómo lo sabe el sistema.** Cuando un paquete instalado requiere reinicio, el sistema crea el flag `/var/run/reboot-required`. Por eso se reinicia **solo si el flag existe**: sin reboot innecesario si nada lo exige, sin saltárselo por descuido si lo exige. Tras reiniciar, `uname -r` muestra el kernel **en ejecución**, que solo entonces coincide con el instalado en disco.

### Por qué el usuario `deploy` va sin contraseña

`adduser --disabled-password` deja la cuenta **sin contraseña** (solo entra por clave SSH). Es la base del modelo de acceso que se cierra más adelante en [Endurecer el acceso](./04_how-to-endurecer-acceso.md): acotar quién puede ser `deploy`, no atar la clave a un único comando.

### Por qué Docker antes de los grupos

El grupo `docker` solo existe después de instalar el engine, por eso la instalación precede al `usermod -aG docker deploy`. Pertenecer al grupo `docker` equivale a ser root en el host: es una implicación de seguridad deliberada que se justifica en [Endurecer el acceso](./04_how-to-endurecer-acceso.md).

### Por qué `daemon.json` antes de levantar servicios

El driver de logs por defecto de Docker (`json-file` sin rotación) **no rota**: `/var/lib/docker` crece sin techo hasta llenar el disco y tumbar el nodo — el modo de muerte más probable de un nodo único. Por eso se escribe `/etc/docker/daemon.json` con `log-driver json-file`, `max-size 10m`, `max-file 3` **antes** de levantar cualquier servicio, no después. No se activa `live-restore`: **Swarm lo ignora**, así que ponerlo sería ruido que sugiere una garantía que no existe.

### Por qué Docker pineado y no `curl | sh` a latest

Instalar con el script de conveniencia a *latest* flotante hace que cada server de la flota termine en una versión distinta según el día en que se aprovisionó: drift invisible, y contradice la propia regla de "nunca latest" que la wiki aplica a las imágenes. Se instala desde el repo APT oficial **pineando** la versión (`docker-ce=<VERSION>`), de modo que el aprovisionamiento sea reproducible. El detalle exacto vive en `provision.sh`.

> **Rootless descartado (tradeoff).** Docker rootless es incompatible con Swarm, así que en este modelo `docker == root` en el host. No se finge lo contrario: el control real es quién puede usar el grupo `docker`, no pretender que sea menos privilegiado de lo que es.

### Por qué un solo nodo manager

`docker swarm init` deja el nodo como manager de un Swarm de un solo nodo. Se inicializa con `--listen-addr 127.0.0.1:2377`: un nodo único no necesita exponer el plano de gestión, y el `init` por defecto abriría `2377/7946/4789` en la IP **pública** antes de que exista el firewall de host. El init se protege con un **guard idempotente** (`docker info | grep -q "Swarm: active" || docker swarm init ...`) para que `provision.sh` se pueda re-correr sin fallar. Si el host tiene varias IP usables, hay que anunciar explícitamente la dirección con `--advertise-addr`. El porqué del modelo de nodo único está en [Modelo de operación](./01_explicacion-modelo-operacion.md).

> **Guardarrail multi-nodo.** Si algún día se suma un nodo, los puertos `2377/7946/4789` se abren **solo** hacia la IP privada del peer, nunca a `0.0.0.0/0`.

### Por qué monitoreo base desde el día 0

El nodo no debe nacer ciego: el disco lleno tira la app **y** Postgres juntos, y los inodos se agotan antes que los bytes en un host Docker. El mínimo es un **systemd timer (~15 min) + script** que mida `df -P /` (bytes), `df -iP /` (inodos), `free -m`, `docker system df` y el tamaño de `pgdata`, con umbrales warn>80% / crit>90%, y un **webhook** (ntfy/Telegram/Slack via `curl`, con la URL como secret) — "escribir al journal" no es una alerta: nadie mira el journal de un VPS que anda bien. La verificación de post-condiciones corre por `verify.sh`. El escalón `node-exporter + Prometheus + Grafana + Alertmanager + Loki` queda como **DIAL** (omisión consciente): es escalación deliberada, no mínimo. La definición mínimo-vs-dial vive en [Referencia de seguridad operativa](./10_referencia-seguridad-operativa.md).

### Runbook de recuperación ante desastre (nodo único)

El modelo es un Swarm de un solo nodo: el manager, PostgreSQL y su volumen viven en la misma VPS. Es un **punto único de fallo (SPOF)** asumido por el dial. Si el nodo se pierde por completo, esta es la secuencia de reconstrucción y lo que la hace posible.

**Qué se respalda y qué no:**

| Activo | Cubierto por | Notas |
|---|---|---|
| Datos de PostgreSQL | Sidecar `backup`: `pg_dump -Fc` diario al Storage Box ([Backups](./09_how-to-backups.md)) | Única copia recuperable del estado de negocio; se suma el dump pre-migración de cada release. |
| Volumen `pgdata` (disco) | Backups del proveedor (habilitados en Fase 0) | El dump lógico es el RPO de negocio; el snapshot de disco es atajo de RTO. |
| Estado del Swarm (raft) | Backups del proveedor (habilitados en Fase 0) | El dump no lo cubre; con backup de imagen se rebuildea, si no, se reconstruye con `docker swarm init`. |
| Docker secrets | `secrets/<env>.env` en gestor de secretos del equipo + 2da ubicación cifrada | Viven solo en el raft del Swarm; se recrean desde estos archivos. |
| Clave del Storage Box (`backup_ssh_key_b64`) | Dentro de `secrets/<env>.env` (la copia off-site de la fila anterior) | Sin ella los dumps del box son **inaccesibles**; `deploy.sh` la recrea como secret. |
| Versión major de PostgreSQL | Spec reconstruible (pineada en el repo) | El dump solo restaura limpio si el destino corre la **misma major**; es parte del runbook, no un detalle. |
| Túnel y DNS | API del proveedor (estado remoto) | El túnel persiste; basta reconectar un conector. |

> **Precondición de supervivencia (SPOF de recovery):** `secrets/<env>.env` (que incluye `backup_ssh_key_b64` y `storage_box_dest`) NO puede vivir solo en el laptop del operador. Laptop + nodo se pierden juntos (incendio, robo, persona que se va) = pérdida **PERMANENTE**, y sin la clave del box los dumps off-site quedan inaccesibles. Por eso se exige **redundancia de llaves**: gestor de secretos del equipo (1Password/Bitwarden/Vault) **y** una segunda ubicación cifrada distinta del laptop. Off-site no es opcional: es lo que hace posible la recuperación.

**Orden de reconstrucción ("prod desde cero"):**

1. Re-aprovisionar una VPS nueva. Camino rápido: restaurar el **golden snapshot** del base endurecido (ver más abajo) para saltarse el aprovisionamiento manual. Camino desde cero: correr `provision.sh` + [Endurecer el acceso](./04_how-to-endurecer-acceso.md).
2. Restaurar `secrets/prod.env` desde la copia off-site (gestor de secretos del equipo) a la máquina del operador: contiene TODOS los valores de secrets, incluidos `backup_ssh_key_b64` y `storage_box_dest`.
3. Recrear el alias SSH y el docker context `${APP}-prod` (mismo nombre) apuntando al nuevo host (ver [Desplegar el stack en Swarm](./06_how-to-desplegar-swarm.md)).
4. Redeplegar con `./deploy.sh prod` desde la máquina del operador: recrea los secrets desde `secrets/prod.env` y materializa servicios, red overlay, `cloudflared` y el sidecar `backup` (que corre un dump al arrancar — el nodo nuevo no queda sin respaldo). La base nace **vacía** y las migraciones corren: hay schema, todavía no datos.
5. Restaurar los datos: bajar del Storage Box el dump diario más reciente (`backups/<stack>/daily/`) — o el pre-migración (`backups/<stack>/pre-migration/` o el local en `backups/`) si es más fresco — y aplicarlo sobre la **misma versión major** ([Backups](./09_how-to-backups.md)): `docker exec -i <db_cid> pg_restore --clean --if-exists -U app -d app_shorter < <dump>`.
6. El conector `cloudflared` reconecta el túnel existente; el dominio vuelve de `inactive`/error 1033 a `healthy` sin tocar el DNS.
7. Verificar con `verify.sh` y `curl https://<dominio>/api/health` -> `200` (`{status, sha}`), túnel `healthy`, datos restaurados.

**Golden snapshot.** Tras dejar el base endurecido (post-instalación de Docker, **antes** de cargar datos) se toma un snapshot "golden" del disco. Es el atajo de RTO: re-crear desde imagen toma minutos contra el aprovisionamiento completo. No respalda datos (eso es el dump off-site); respalda la **maquinaria**.

**Cadencia de DR drill.** El RTO/RPO no son afirmaciones, son mediciones: el runbook se prueba **end-to-end** con cadencia fija (p. ej. trimestral) restaurando en un host descartable y cronometrando. Un runbook que nunca corrió es una hipótesis, no una garantía.

**RPO y RTO:**

| Métrica | Valor | De qué depende |
|---|---|---|
| RPO (pérdida máxima de datos) | aproximadamente la ventana del backup diario (~24 h) | Cadencia del sidecar `backup`; el dump pre-migración de cada release la acorta; escalones del dial (restic, WAL archiving) en [Backups](./09_how-to-backups.md). |
| RTO (tiempo de recuperación) | golden snapshot + restore + redeploy | Se baja con golden snapshot y backups de imagen del proveedor; sin ellos, dominado por el aprovisionamiento del host y el tamaño del restore. |

---

## Camino verificado

El procedimiento ejecutado paso a paso, con comandos y salidas esperadas. Los valores concretos del host (hostname, IP, IDs, versiones) se observaron en una ejecución real y aparecen parametrizados: sustituilos por los de tu nodo.

> Estos comandos son la **explicación legible** de lo que hace `provision.sh`. En un nodo real se corre el script (idempotente); copiarlos a mano es el camino de aprendizaje o de fallback. Ante cualquier divergencia, la verdad es el script.

### Paso 0 — Antes del primer boot (consola/API del proveedor)

Esto se hace **sin SSH**, antes de encender el server. Este es el **QUÉ** (checklist); el **CÓMO** ejecutable —los comandos `hcloud`, el wrapper y sus guardarraíles— vive en [Gestionar la infraestructura vía API](./12_how-to-gestionar-infra-via-api.md), que es el hogar de esa doctrina:

1. **Firewall de borde como código**: el ruleset versionado `operaciones/firewall-rules.json` (inbound `deny-all` salvo `22/tcp` en **ambas** familias v4 y v6; egress permitido) se converge con una operación atómica desde el archivo, nunca incremental; su historial de git es el log de auditoría del borde — [ops/12 §Firewall declarativo](./12_how-to-gestionar-infra-via-api.md#firewall-declarativo-por-api-replace-rules--diff-gate).
2. **Confirmar-o-crear por label**: `server create` no es idempotente; se crea **solo** si el selector por label vuelve vacío y `>1 match` = parar. El server nace con la clave SSH adjunta, **sin** password de root y etiquetado: el label es la identidad — [ops/12 §Confirmar-o-crear](./12_how-to-gestionar-infra-via-api.md#confirmar-o-crear-por-label-idempotente).
3. **Backups del proveedor + protección ejecutable**: habilitar `--enable-backup` al crear (~+20% del costo; paso del protocolo, no opcional) y encender acto seguido `enable-protection delete rebuild`, que impide borrar o reconstruir el server incluso con token Read&Write — [ops/12 §Guardarraíles del token](./12_how-to-gestionar-infra-via-api.md#guardarraíles-del-token).
4. **Defaults de plantilla**: tipo de server, location y decisión dual-stack vs IPv4-only (el Primary IPv4 se factura aparte).
5. **`cloud-init`** (`operaciones/user_data.yaml`) como `user_data`: en el primer boot crea `deploy`, inyecta su pubkey y aplica el hardening base.

Estos pasos viven en `provision.sh` (porción de Fase 0) y `user_data.yaml`. La **IP del server no se cachea como verdad**: se re-deriva siempre desde la API, porque persistirla crea una segunda fuente de verdad que driftea tras cada rebuild — [ops/12 §Estado recuperable](./12_how-to-gestionar-infra-via-api.md#estado-recuperable-la-api-es-la-verdad-la-ip-se-deriva). La consola del proveedor no se parametriza aquí para mantener la plantilla genérica.

### Paso 1 — Estado base del SO

Conectate por SSH como `root` y aplica las actualizaciones a fondo:

```bash
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
apt update && apt full-upgrade -y
```

Fija timezone UTC y confirma la sincronización horaria (sin instalar `chrony`):

```bash
timedatectl set-timezone UTC
timedatectl set-ntp true
timedatectl show -p NTPSynchronized   # espera NTPSynchronized=yes
```

Crea un swapfile modesto de 2G y baja `swappiness` (red de seguridad contra el OOM killer):

```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
grep -qxF '/swapfile none swap sw 0 0' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf && sysctl --system
swapon --show
```

Acota y persiste el journal (del que depende `fail2ban`):

```bash
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-limits.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
EOF
systemctl restart systemd-journald
journalctl --header | grep -i persistent
```

Si el `full-upgrade` instala un kernel nuevo, continúa con el Paso 1b. Si no, salta al Paso 1c.

### Paso 1b — Reiniciar si se instaló un kernel nuevo

Comprobá el flag de reinicio pendiente y reinicia solo si existe:

```bash
[ -f /var/run/reboot-required ] && systemctl reboot
```

El reinicio **corta tu sesión SSH**. Espera a que el servidor vuelva, reconectate como `root` y confirma el kernel activo con `uname -r`.

### Paso 1c — Activar el auto-parcheo (recomendado)

```bash
apt install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/51-auto-reboot <<EOF
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
```

`Automatic-Reboot` reinicia **solo** si un parche dejó `/var/run/reboot-required`, en la ventana `04:00` de bajo tráfico. Sin esto, los parches de kernel se instalan pero el nodo sigue corriendo el kernel viejo vulnerable. Verifica que el timer quedó activo y que la config de reboot está puesta:

```bash
systemctl is-enabled apt-daily-upgrade.timer
grep -ri reboot /etc/apt/apt.conf.d/
```

### Paso 2 — Crear el usuario `deploy`

```bash
adduser --disabled-password --gecos "" deploy
```

`--disabled-password` deja la cuenta sin contraseña (solo entra por clave SSH); `--gecos ""` omite las preguntas interactivas. Si `deploy` ya existía, el comando avisa y el resultado es igualmente correcto. Confirmalo con `id deploy` y `passwd -S deploy` (estado `L` = locked).

### Paso 3 — Instalar Docker (pineado) con rotación de logs

Primero escribe `/etc/docker/daemon.json` **antes** de que exista cualquier servicio, para que el driver de logs rote desde el arranque y `/var/lib/docker` no se llene:

```bash
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
```

No se incluye `live-restore`: Swarm lo ignora. Instala Docker **antes** de tocar los grupos del usuario (el grupo `docker` solo existe después del engine) y **pineando la versión** desde el repo APT oficial, no `curl | sh` a *latest* flotante:

```bash
# Repo oficial de Docker + pin de version (reproducible entre servers)
apt install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt update
apt install -y docker-ce=<VERSION> docker-ce-cli=<VERSION> containerd.io docker-compose-plugin docker-buildx-plugin
apt-mark hold docker-ce docker-ce-cli
```

Sustituí `<VERSION>` por la versión pineada de la plantilla. Verifica:

```bash
docker --version
docker ps
```

`docker ps` debe devolver una lista vacía **sin error**, y el `daemon.json` debe estar activo antes del primer servicio.

### Paso 4 — Dar permisos de Docker a `deploy`

```bash
usermod -aG docker deploy
id deploy
```

`-aG` agrega `deploy` al grupo `docker` **sin quitarlo** de los demás. Con eso, `deploy` podrá usar `docker`, `stack`, `service`, `secret` y `swarm` sin `sudo`. El nuevo grupo se aplica en la **próxima** sesión de `deploy`.

### Paso 5 — Inicializar el Swarm

Antes de inicializar, revisa cuántas direcciones IP usables tiene el servidor:

```bash
ip -brief -4 addr
```

Si hay **una sola** dirección usable (caso típico), inicializa con el plano de gestión escuchando solo en loopback y un guard idempotente para poder re-correr `provision.sh` sin fallar:

```bash
docker info 2>/dev/null | grep -q "Swarm: active" || docker swarm init --listen-addr 127.0.0.1:2377
```

`--listen-addr 127.0.0.1:2377` evita que el `init` abra `2377/7946/4789` en la IP pública antes de que exista el firewall de host. Si el servidor tiene **varias** interfaces con IP, `docker swarm init` fallará con `could not choose an IP address... multiple addresses`. En ese caso, indica explícitamente la dirección a anunciar (manteniendo el listen en loopback):

```bash
docker info 2>/dev/null | grep -q "Swarm: active" || docker swarm init --listen-addr 127.0.0.1:2377 --advertise-addr <IP-del-servidor>
```

Confirma que el nodo quedó como manager activo:

```bash
docker node ls
docker info | grep -i swarm
```

`docker node ls` debe mostrar el nodo como `Ready` / `Active` con rol `Leader`.

### Paso 6 — Monitoreo base del host

Antes de dar por listo el nodo, dejalo viendo. El mínimo es un timer + script que mida disco (bytes e **inodos**), memoria y uso de Docker/`pgdata`, más un webhook de alerta. La implementación vive en el script de monitoreo de la plantilla (referenciado por `provision.sh`); aquí se valida que quedó armado:

```bash
systemctl is-enabled <monitor>.timer       # timer de monitoreo activo
systemctl status <monitor>.timer --no-pager
df -iP /                                    # inodos: se agotan antes que los bytes en hosts Docker
```

Cierra el aprovisionamiento corriendo la verificación de post-condiciones:

```bash
./verify.sh        # sale ≠0 si alguna post-condicion falla
```

`verify.sh` es el gate de aceptación (firewall activo con regla v6, SSH endurecido efectivo, Swarm `active`+Leader, auto-parcheo habilitado, timers activos). El stack de observabilidad completo (`node-exporter`/Prometheus/Grafana) es **DIAL**, no mínimo.

> **Sin tablas espejo.** Los comandos exactos por paso, sus flags y las salidas observadas de una ejecución real viven en `provision.sh` (que los ejecuta) y `verify.sh` (que los aserta como post-condiciones). Duplicarlos aquí solo crearía deriva: si el doc y el script difieren, gana el script.

### Rutas de archivos relevantes

| Ruta | Qué es |
|---|---|
| `operaciones/provision.sh` | Fuente de verdad ejecutable del aprovisionamiento (idempotente). |
| `operaciones/verify.sh` | Verificación de post-condiciones (gate de aceptación). |
| `operaciones/user_data.yaml` | Plantilla cloud-init para el bootstrap del primer boot. |
| `/var/run/reboot-required` | Flag de reinicio pendiente tras instalar un kernel. |
| `/boot/vmlinuz` | Enlace al kernel que se cargará en el próximo arranque. |
| `/etc/apt/apt.conf.d/20auto-upgrades` | Configuración del auto-parcheo (Paso 1c). |
| `/etc/apt/apt.conf.d/51-auto-reboot` | Reinicio automático de unattended-upgrades en ventana 04:00. |
| `/swapfile` + `/etc/sysctl.d/99-swappiness.conf` | Swap 2G y `vm.swappiness=10`. |
| `/etc/systemd/journald.conf.d/00-limits.conf` | Journal persistente y capeado (base de fail2ban). |
| `/etc/docker/daemon.json` | Rotación de logs de Docker (antes de levantar servicios). |

---

## Lo que sigue

Con el servidor en Swarm, el siguiente objetivo es **endurecer el acceso**: clave SSH de `deploy`, `sudo`, firewall, `fail2ban` y hardening de SSH (cerrar el login de `root` y la autenticación por contraseña), en [Endurecer el acceso](./04_how-to-endurecer-acceso.md).
