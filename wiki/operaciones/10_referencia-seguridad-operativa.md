---
id: ops.seguridad-operativa
titulo: Seguridad operativa
tipo: referencia
tier: 3
audience: both
resumen: Inventario consolidado (checklist) de los controles de seguridad operativa del nodo y su modelo de defensa en profundidad.
provides:
  - "inventario consolidado de controles de seguridad operativa (el doc como checklist de referencia)"
  - "modelo de defensa en profundidad del nodo (cómo se combinan los controles)"
  - "política de retención de logs json-file (max-size / max-file) como guardarraíl de disponibilidad de disco"
  - "controles CIS deliberadamente fuera del dial, con control alternativo declarado"
  - "separación de planos: fail2ban solo el 22; app-layer = Cloudflare"
  - "observabilidad de disco por inodos además de bytes (df -iP; en hosts Docker los inodos se agotan antes que los bytes)"
reads-before: [ops.endurecer-acceso, ops.secretos]
related: []
---

# Seguridad operativa

**Índice consolidado**: reúne todos los controles de seguridad de la operación y el deploy como checklist de referencia. Cada control se define y justifica en su documento primario; aquí solo se inventarían y se muestra cómo se combinan.

La **fuente de verdad ejecutable** es `verify.sh`, el script de post-condiciones del aprovisionamiento. Regla rectora: **cada control se verifica por su efecto, no por su existencia** — no alcanza con un paquete instalado o un servicio `running`; lo que se acepta es la post-condición observable (un puerto cerrado, una opción efectiva, un ban en el ruleset). El checklist de [Camino verificado](#camino-verificado) mapea cada ítem a la aserción concreta que `verify.sh` automatiza: el `.md` explica el **porqué**; el script es lo que **falla en rojo** si la post-condición no se cumple.

## Norma

### Defensa en profundidad del nodo

Ningún control alcanza por sí solo. La seguridad operativa de un nodo único surge de **capas independientes** que se cubren mutuamente: si una falla, otra contiene el daño. Cuatro planos.

1. **Acceso al host.** Quién puede entrar al servidor y con qué privilegios. Solo clave, sin root, sin password, con firewall y bloqueo de fuerza bruta.
2. **Superficie de red.** Qué puertos están expuestos. La app no abre puertos entrantes: su tráfico entra por una conexión saliente. El único puerto entrante es el de administración.
3. **Manejo de secretos.** Cómo viven las credenciales en reposo y en tránsito. Cifrados en el orquestador, montados como archivos, nunca en la imagen ni en el repositorio.
4. **Cadena de suministro y privilegio de la app.** Qué corre dentro del nodo y con qué permisos. Imágenes inmutables verificables, dependencias auditadas, contenedor sin privilegios y autorización deny-by-default.

A estos cuatro planos se suman dos **guardarraíles de disponibilidad** que son seguridad en sentido amplio (mantener el servicio vivo y recuperable):

- **Retención de logs y disco acotado** para que el almacenamiento no se agote (cota de logs de Docker, cota de `journald`, y observabilidad de bytes **e inodos**).
- **Supervivencia ante pérdida del nodo**: secretos y passphrases de backup mantenidos fuera del servidor.

> **Alcance de `fail2ban`.** Defiende **solo el puerto 22 (SSH)**; la defensa app-layer es el WAF + Rate Limiting de Cloudflare delante del túnel — dos planos distintos, ninguno cubre al otro. El porqué completo del malentendido vive en [Endurecer el acceso](./04_how-to-endurecer-acceso.md).

### Guardarraíl de disco: logs, journald e inodos

En un nodo único, **el disco lleno es el modo de muerte más probable**: cuando `/` se agota, caen juntas la aplicación y la base de datos. Tres frentes, los tres verificados por su efecto en `verify.sh`.

1. **Logs de Docker (`json-file`).** Los logs del stack salen como JSON a stdout y el driver de Docker los persiste en el host. Sin cota, ese volumen crece sin techo. Cada servicio acota su logging con `max-size` y `max-file`:

   ```yaml
   logging:
     driver: json-file
     options:
       max-size: "10m"
       max-file: "3"
   ```

   El mismo tope se fija como default del daemon en `daemon.json` (`log-driver`/`max-size`/`max-file`) para que **ningún** contenedor escape a la rotación, incluso los que no declaran `logging`. Los valores por servicio viven en `stack.yml`; el default del daemon se escribe en el aprovisionamiento ([Aprovisionar el servidor](./03_how-to-aprovisionar-servidor.md)).

2. **`journald` acotado.** El journal del sistema compite por el mismo disco que los logs de Docker; sin cota crece en paralelo y anula la protección anterior. Se acota con `Storage=persistent` y `SystemMaxUse` (p. ej. `500M`) en un drop-in de `journald.conf.d`. Además de disco, es guardarraíl de **integridad de la defensa**: `fail2ban` usa `backend=systemd`, así que un journal volátil o purgado pierde el historial de bans tras un reboot.

3. **Inodos, no solo bytes.** En un host Docker los inodos se agotan **antes** que los bytes (muchas capas y archivos pequeños). Un disco que `df -h` muestra con espacio libre puede estar 100% lleno de inodos y rechazar toda escritura. El monitoreo mide ambas dimensiones: `df -P /` (bytes) **y** `df -iP /` (inodos), con los mismos umbrales warn>80% / crit>90%.

Guardarraíl de **disponibilidad**, no de orden: cada frente pone un techo fijo a una vía distinta de agotamiento del disco.

### Monitoreo: mínimo obligatorio vs. dial

El nodo no debe **nacer ciego**. La precondición para confiar en cualquier guardarraíl de disco es poder verlo agotarse antes de que tire el servicio. Se define un piso obligatorio y una escalación opcional.

- **Mínimo obligatorio (entra al protocolo): `timer` + `script` + `webhook`.** Un `systemd` timer (~15 min) corre un script bash que mide `df -P /` (bytes), `df -iP /` (inodos), `free -m`, `docker system df` y el `du` de `pgdata`, con umbrales warn>80% / crit>90%. Al cruzar un umbral notifica por **webhook** (ntfy/Telegram/Slack vía `curl`, con la URL como secret), con contrato mínimo: host, rubro, porcentaje, umbral. Regla: *"escribir al journal" no es una alerta* — nadie mira el journal de un VPS que anda bien.
- **Dial (escalación deliberada, NO se implementa hoy): `node-exporter` + Prometheus + Grafana + Alertmanager + Loki.** Es la solución correcta para una flota o cuando se necesitan series históricas, dashboards y reglas de alerta ricas. Para un nodo único de agencia chica es sobre-ingeniería: agrega componentes que también hay que mantener, asegurar y respaldar. Queda como **omisión consciente**: el día que haya varios nodos o requisitos de SLA, se sube el dial.

### Controles CIS deliberadamente fuera del dial

Endurecer no es maximizar. Un VPS de nodo único no es un host multi-tenant de cumplimiento; aplicar a ciegas un benchmark CIS completo agrega operación, rompe componentes y da falsa sensación de seguridad sin reducir el riesgo real de **esta** plantilla. Los siguientes controles quedan **fuera del dial a propósito**, no por olvido:

| Control omitido | Por qué queda fuera | Qué cubre el caso en su lugar |
|---|---|---|
| **`auditd`** | Genera un volumen de eventos que nadie revisa en un nodo único y compite por disco. | El `journald` persistente y acotado ya da la traza operativa que se consulta de verdad. |
| **`/tmp` con `noexec`** | Rompe `needrestart`, `apt` y hooks de paquetes que ejecutan desde `/tmp`; genera incidentes de mantenimiento sin cerrar un vector real aquí. | El contenedor corre sin privilegios y la superficie de ejecución está en imágenes inmutables, no en `/tmp` del host. |
| **Blacklist de módulos de kernel exóticos** | Mantener una lista de módulos raros (firewire, usb-storage, protocolos legacy) es operación recurrente sin beneficio en un VPS cloud sin esos buses. | El kernel parcheado al día (`unattended-upgrades` con auto-reboot) cubre el riesgo realista. |
| **`--autolock` del raft de Swarm** | El autolock exige reingresar la unlock key en cada arranque del daemon, lo que **choca de frente con el reboot desatendido** del parcheo automático: el nodo no volvería solo. | Control de acceso al host: el raft cifrado en reposo se protege limitando *quién* puede entrar al servidor (Fase de acceso), no bloqueando el arranque. |
| **CrowdSec** | Es una defensa multi-nodo / app-layer; sobre un único puerto SSH, `fail2ban` ya alcanza. La defensa app-layer no vive en el host (ver alcance de `fail2ban` arriba). | `fail2ban` para SSH; **WAF + Rate Limiting de Cloudflare** para la app. |
| **OpenSCAP / CIS completo** | Suite pesada de evaluación pensada para auditoría de compliance; para este alcance es sobre-instrumentación. | `Lynis` como gate de auditoría (Hardening Index con umbral) da la atestación independiente suficiente. |

Criterio común: **cada omisión declara qué control alternativo cubre el caso**. No es renunciar a la defensa; es elegir la capa que de verdad reduce el riesgo de un nodo único y dejar por escrito el tradeoff para cuando el contexto (flota, compliance, multi-tenant) justifique subir el dial.

### Gestión de infra por el agente

Cuando un agente de IA gestiona el ciclo de vida del servidor vía la API de Hetzner, el control **no puede apoyarse en el scope del token** (solo Read o Read&Write por proyecto, sin IAM fino): surge de **capas independientes** que se cubren mutuamente, igual que la defensa en profundidad del nodo — la matriz autónomo / human-confirmed / prohibido, el wrapper como choke-point, los dos tokens segregados y la protección a nivel API. Esa doctrina completa, incluido el anti-patrón "abrir el borde para arreglar una app" (el agente solo propone diffs con token read; todo apply mutante del firewall es human-confirmed), vive en [Gestionar la infra vía API](./12_how-to-gestionar-infra-via-api.md).

## Camino verificado

Checklist consolidado de los controles aplicados. Cada ítem remite a su documento primario (que lo define y justifica) y a la **post-condición** que `verify.sh` aserta — la casilla se marca cuando el script pasa en verde, no cuando el paquete está instalado. `verify.sh` sale con código ≠0 si cualquier aserción falla; es el gate de aceptación del nodo y su reporte fechado PASS/FAIL se retiene fuera del host.

### Acceso al host

- [ ] **Usuario `deploy`, no root.** El pipeline opera con un usuario `deploy` en el grupo `docker`. Atención: estar en el grupo `docker` equivale a root en la máquina (se puede montar el filesystem del host desde un contenedor). Es inevitable para este flujo; el modelo acota *quién* puede ser `deploy`, no *qué* puede hacer con Docker. — `verify.sh`: `id deploy` confirma el grupo `docker` y `root` no puede loguear (`sshd -T` → `permitrootlogin no`). Ver [Endurecer el acceso](./04_how-to-endurecer-acceso.md).
- [ ] **No "atar" la clave a un solo comando.** El candado de `authorized_keys` a un único `docker stack deploy` rompe el pipeline, que también corre `docker secret create`, `service create`, `exec` y `network inspect`. Es falsa seguridad; la protección va por otro lado. Ver [Endurecer el acceso](./04_how-to-endurecer-acceso.md).
- [ ] **SSH endurecido por efecto, no por sintaxis.** Login de root deshabilitado, autenticación por contraseña deshabilitada (solo clave) y `fail2ban`. El usuario `deploy` entra solo por clave (`--disabled-password`). — `verify.sh`: `sshd -T | grep -Ei "passwordauthentication|permitrootlogin|allowusers"` debe dar `no`/`no`/`deploy` (config **efectiva**; `sshd -t` solo valida sintaxis y da falso OK). Ver [Endurecer el acceso](./04_how-to-endurecer-acceso.md).
- [ ] **Ban funcional de `fail2ban`, no solo `running`.** — `verify.sh`: el jail `sshd` está activo y un ban de prueba aparece en `nft list ruleset` (un jail puede correr "running" sin banear nunca por mismatch de `banaction`). Recordar el alcance: defiende **solo el puerto 22** (ver Norma). Ver [Endurecer el acceso](./04_how-to-endurecer-acceso.md).

### Superficie de red

- [ ] **Firewall (host + borde).** Solo SSH (22) entrante. El tráfico HTTP de la app **no** necesita puertos abiertos: entra por el túnel saliente. El conector solo necesita **egress** hacia el proveedor del túnel (puerto 7844). — `verify.sh`: `ufw status verbose` activo con regla v4 **e** v6 para 22 (una regla solo-v4 deja el puerto abierto por IPv6 con `ufw status` viéndose limpio). Nota para CI: los runners hospedados no tienen IP fija; si se filtra SSH por IP no entran — dejar SSH solo con clave (más `fail2ban`), usar un runner self-hosted, o tunelizar SSH por el mismo proveedor. Ver [Endurecer el acceso](./04_how-to-endurecer-acceso.md).

### Manejo de secretos

- [ ] **Secretos.** Cifrados en el swarm, montados como archivos, nunca en la imagen ni en el repositorio. Inmutables; se rotan recreándolos. Ver [Secretos](./07_referencia-secretos.md).

### Cadena de suministro y privilegio de la app

- [ ] **Cadena de suministro.** Imágenes privadas en el registry tageadas por SHA del commit (nunca `latest`); las actions del pipeline fijadas a tag inmutable/SHA; la auditoría del árbol de dependencias y las reglas de seguridad del linter corren en cada `check` del contrato. El tageo por SHA como unidad inmutable se detalla en el [Modelo de operación](./01_explicacion-modelo-operacion.md).
- [ ] **Mínimo privilegio en la app.** El contenedor final corre como usuario sin privilegios (ver [Entornos e imagen Docker](./02_referencia-entornos-e-imagen.md)). La autorización es deny-by-default por scopes. El token del proveedor del túnel se provisiona con un API token **con scope acotado** (Tunnel: Edit; DNS: Edit; Zone: Read), nunca con la Global API Key — ver [Exponer la app por Cloudflare Tunnel](./05_how-to-exponer-cloudflare-tunnel.md).
- [ ] **Actualizaciones del servidor con reinicio.** `unattended-upgrades` mantiene el host parcheado de forma automática **y reinicia en ventana** (`Automatic-Reboot` + `Automatic-Reboot-Time`); sin el reboot, el kernel parcheado queda en disco pero el nodo sigue corriendo el kernel viejo vulnerable. — `verify.sh`: servicio enabled y `unattended-upgrade --dry-run -d` lista orígenes de seguridad. Ver [Aprovisionar el servidor](./03_how-to-aprovisionar-servidor.md).

### Guardarraíles de disponibilidad

- [ ] **Cota de logs de Docker.** Cada servicio acota su logging (`json-file` con `max-size` y `max-file`) y el mismo tope se fija como default del daemon en `daemon.json`, para que los logs no agoten el disco del nodo único. Control del que este documento es fuente; los valores por servicio están en `stack.yml` y el default del daemon en la [referencia de aprovisionamiento](./03_how-to-aprovisionar-servidor.md).
- [ ] **Cota de `journald`.** `Storage=persistent` + `SystemMaxUse` para que el journal no compita por disco con los logs de Docker y para que `fail2ban` (`backend=systemd`) conserve el historial de bans tras reboot.
- [ ] **Observabilidad de disco (bytes **e** inodos).** Timer + script que mide `df -P /` y `df -iP /` con umbrales warn>80% / crit>90% y notifica por webhook; los inodos se agotan antes que los bytes en hosts Docker. Mínimo obligatorio = timer+script+webhook (ver Norma → Monitoreo).
- [ ] **Supervivencia ante pérdida del nodo.** Los Docker secrets viven solo en el raft del Swarm y los backups se descifran con su passphrase; ambos se recrean o se leen desde **fuera** del servidor (`secrets/<env>.env` y la passphrase del operador en un gestor de secretos del equipo más una segunda ubicación cifrada ≠ laptop). Mantenerlos off-site con redundancia es la precondición que hace recuperable un nodo único; el laptop solo es un SPOF de recovery. Ver el [runbook de recuperación ante desastre](./03_how-to-aprovisionar-servidor.md#runbook-de-recuperación-ante-desastre-nodo-único).

### Gestión de infra por el agente (API de Hetzner)

Controles que aplican cuando un agente de IA opera el ciclo de vida del servidor vía `hcloud`. Su fuente de verdad ejecutable es `infra-verify.sh` (gate de post-condiciones a nivel API, simétrico a `verify.sh`); cada control se define y justifica en [Gestionar la infra vía API](./12_how-to-gestionar-infra-via-api.md).

- [ ] **Drift del borde monitoreado.** El ruleset versionado `firewall-rules.json` se diffea contra el estado vivo y el drift alerta por el mismo webhook del monitoreo. — `infra-verify.sh`: reglas vivas == archivo; `22/tcp` abierto en v4 **y** v6 y **nada más** inbound.
- [ ] **Auditoría off-host de cada mutación del agente.** El wrapper `hcloud-agent.sh` es el único choke-point y emite una traza append-only fuera del host (el host es justo lo que un compromiso podría borrar).
- [ ] **Matriz de capacidades como defensa en profundidad.** Tres clases (autónomo / human-confirmed / prohibido) fijadas por el daño irreversible, reforzadas a nivel API por `enable-protection delete rebuild`.
- [ ] **El agente no abre el borde para arreglar una app.** Solo propone diffs con token read; todo apply mutante del firewall es human-confirmed. — `infra-verify.sh`: ningún inbound fuera de `22/tcp` v4+v6.
