---
id: ops.endurecer-acceso
titulo: Endurecer el acceso
tipo: how-to
tier: 3
audience: both
resumen: Endurecer el acceso al servidor (clave ed25519, sudoers, ufw, fail2ban, drop-in SSH) y el modelo de seguridad del grupo docker con su orden de cierre seguro.
provides:
  - "generación de clave ed25519 local (la clave privada nunca llega al servidor)"
  - "instalación manual de la clave pública (no ssh-copy-id; authorized_keys 600; install -d -m 700)"
  - "sudoers.d NOPASSWD / visudo -cf"
  - "ufw (default deny incoming, allow outgoing, allow 22/tcp)"
  - "fail2ban backend=systemd (no hay auth.log; jail.local)"
  - "sshd_config.d/00-hardening.conf (00- gana precedencia sobre 50-cloud-init.conf; PermitRootLogin no, PasswordAuthentication no, PubkeyAuthentication yes; sshd -T efectivo; reload ssh)"
  - "grupo docker == root en el host (modelo de seguridad)"
  - "antipatrón de restringir la clave SSH a un solo comando (falsa seguridad, rompe el pipeline)"
  - "inversión del modelo (acota quién puede ser deploy, no qué puede hacer deploy con Docker)"
  - "barrera de verificación (probar la puerta nueva antes de cerrar la vieja) / autobloqueo / break-glass = Rescue System del proveedor (root queda bloqueada; no consola-con-password)"
  - "NOPASSWD justificado para una cuenta --disabled-password"
  - "por qué el firewall solo abre SSH (el HTTP entra por túnel saliente)"
  - "endurecimiento sysctl de la pila de red (CIS L1; después de Docker)"
  - "dos claves SSH para deploy (operador con passphrase vía ssh-agent vs CI sin passphrase como secret del repo)"
  - "precedencia de drop-ins de sshd (verificar con sshd -T)"
  - "verificación funcional del ban de fail2ban (banip de prueba debe aparecer en nft list ruleset; banaction nftables-multiport)"
  - "auditoría independiente con Lynis (Hardening Index >=70 + cero warnings; reporte fechado off-host)"
reads-before: [ops.aprovisionar]
related: []
---

# Endurecer el acceso

Esta guía endurece el acceso de un servidor ya aprovisionado hasta Docker Swarm: instala las claves SSH autorizadas del usuario `deploy` (operador humano y CI), le concede `sudo`, levanta el firewall y `fail2ban`, endurece SSH para deshabilitar el login de `root` y la autenticación por contraseña, y endurece la pila de red del kernel. **Norma** explica el modelo de seguridad que justifica cada decisión; **Camino verificado** es el procedimiento ejecutado paso a paso.

> **Fuente de verdad.** Estos pasos están codificados como artefacto ejecutable e idempotente en `provision.sh` (aplicación) y `verify.sh` (post-condiciones), versionados junto a este doc. El procedimiento de abajo explica el **porqué** de cada decisión; los scripts son lo que efectivamente corre. Si el script y la prosa divergen, gana el script y se corrige el doc.

Asume que ya tienes:

- Un servidor [aprovisionado hasta Docker Swarm](./03_how-to-aprovisionar-servidor.md), con el usuario `deploy` creado `--disabled-password` y en el grupo `docker`.
- Acceso SSH como `root` **todavía abierto**.
- Una máquina local con cliente SSH, desde donde te conectarás como `deploy`.
- Competencia básica con la línea de comandos de Linux y SSH.

Los comandos del servidor se ejecutan **como `root`**; los que se ejecutan **en tu máquina local** están marcados como tales.

---

## Norma

La regla portable: por qué pertenecer al grupo `docker` equivale a ser `root`, dónde se concentra entonces la defensa, y por qué el cierre del acceso sigue un orden innegociable.

### Grupo `docker` = root en el host

Sumar `deploy` al grupo `docker` le da, de hecho, **acceso root al host**. El daemon de Docker corre como `root`, y quien pueda hablar con él puede levantar un contenedor que **monte el sistema de archivos del host** y lo modifique con privilegios de `root` —equivalente a una shell de `root`—, sin `sudo` y sin el rastro habitual de una escalada. El grupo `docker` no es un permiso acotado "para usar contenedores": equivale a estar en `sudoers` sin contraseña.

### Por qué lo aceptamos igual: la inversión del modelo

Ese privilegio es **inevitable** para este flujo. `deploy` opera el clúster: `docker stack deploy`, `docker secret create`, `docker service create`, `docker exec`, `docker network inspect`. Todas requieren hablar con el daemon, y no existe un subconjunto "seguro" del grupo `docker` que permita desplegar pero impida montar el host: es el mismo canal de control.

La pregunta correcta no es "¿cómo evito que `deploy` sea root?" (no se puede sin romper su trabajo) sino "¿cómo evito que alguien que no es `deploy` llegue a serlo?". El riesgo se traslada del **privilegio** (necesario) al **acceso** (controlable): no se acota *qué* puede hacer `deploy` con Docker, se acota *quién* puede ser `deploy`.

### El antipatrón: restringir la clave SSH a un solo comando

Tentación habitual: restringir la clave SSH de `deploy` en `authorized_keys` a **un** comando fijo (p. ej. `docker stack deploy`), bajo la idea de que "si la clave solo despliega, da igual que el grupo `docker` sea root". Pero el pipeline real no es un solo comando: también hace `docker secret create`, `service create`, `exec`, `network inspect`. Atar la clave a un comando único o rompe el despliegue o se afloja hasta no proteger: falsa sensación de seguridad que estorba más de lo que protege.

### Dónde sí ponemos la protección

La defensa se concentra en el **acceso al servidor**:

- **Solo clave SSH, nunca contraseña.** `deploy` se crea con `--disabled-password`: no hay contraseña que adivinar ni filtrar; el único modo de ser `deploy` es poseer su clave privada.
- **Firewall mínimo.** Solo el puerto 22 entrante.
- **`fail2ban`** sobre SSH, para frenar la fuerza bruta.

Como ser `deploy` ya implica poder ser `root`, toda la inversión va en que **nadie más que el dueño de una clave autorizada pueda ser `deploy`**.

### Dos claves para `deploy`: la del operador humano y la de CI

`deploy` no tiene una sola clave: tiene un `authorized_keys` que acumula **una clave por identidad autorizada**, y esas identidades son de dos naturalezas distintas que **no hay que confundir**:

- **Clave del operador humano.** Una persona que administra el servidor desde su máquina. Se genera **con passphrase** y se usa a través de `ssh-agent`: la passphrase cifra la clave privada en reposo, de modo que un robo del disco del laptop no entrega acceso directo al servidor. El operador la desbloquea una vez por sesión en el agente; no la teclea en cada conexión. Hay **una clave por persona y por host** (no se comparte el archivo entre máquinas ni personas): dar de baja a alguien o reciclar un laptop comprometido es borrar **una** línea de `authorized_keys`, sin tocar a los demás.

- **Clave de CI / deploy automático.** El pipeline que despliega sin un humano delante (p. ej. un job de GitHub Actions) corre desatendido y **no puede** detenerse a pedir una passphrase interactiva. Por eso su clave se genera **sin passphrase** y se protege como **secret del repositorio** (GitHub Actions secret), no en disco plano. Su protección no es la passphrase —imposible en automatización— sino el control de acceso del almacén de secrets y el hecho de que solo vive en el runner durante el job.

La regla: **la passphrase protege la clave del humano; el almacén de secrets protege la de CI.** Aplicarle passphrase a la clave de CI rompería el pipeline (se colgaría esperando un input que nadie va a dar); dejar sin passphrase la clave del operador tira a la basura la única defensa de esa clave en reposo. Son dos decisiones de seguridad distintas para dos amenazas distintas.

### Por qué el orden de cierre evita el autobloqueo

Asegurar el acceso es cambiar una puerta por otra: abrir la nueva (clave de `deploy` con `sudo`) y tapiar la vieja (login de `root` y autenticación por contraseña). Si cierras `root` o la contraseña **antes** de comprobar que la clave nueva funciona —clave mal pegada, permiso de más en `authorized_keys`, `sudoers` roto—, te quedas sin ninguna puerta, porque el medio para arreglarlo es el que tapiaste. En un servidor remoto eso significa, en el mejor caso, el **Rescue System** del proveedor (Paso 7); en el peor, reinstalar.

Por eso el procedimiento pone una **barrera de verificación** entre abrir y cerrar: instalar la clave, dar el `sudo`, abrir una sesión real como `deploy` y confirmar las tres cosas —entra con su clave, escala a `root` con `sudo`, opera Docker—. Solo entonces, y con la sesión `root` todavía abierta como red de seguridad, se endurece SSH. Regla: **nunca cierres una vía de acceso sin haber probado la que la reemplaza.**

### Por qué `NOPASSWD` con una cuenta `--disabled-password`

`deploy` se crea sin contraseña a propósito. Pero la forma clásica de dar `sudo` (sumar al grupo `sudo`) pide por defecto la **contraseña del propio usuario**. Una cuenta `--disabled-password` no tiene esa contraseña: `sudo` pediría algo que nadie puede teclear y `deploy` no escalaría nunca; el privilegio existiría en el papel y sería inútil.

`NOPASSWD` resuelve el choque: `sudo` no pide contraseña a `deploy`. No debilita el modelo porque la autenticación ya ocurrió un escalón antes, en SSH: para teclear `sudo` hay que haber entrado, y entrar exige una clave privada autorizada de `deploy`. La identidad vive en la clave SSH; `sudo` solo confirma la intención de escalar.

Sobre el alcance: `NOPASSWD:ALL` es **administración total del host**, no un permiso acotado. No contradice el modelo "sin contraseña" de `deploy` —lo completa—: `deploy` ya es `root` de hecho por pertenecer al grupo `docker` (ver arriba), así que `NOPASSWD:ALL` no agrega privilegio nuevo, solo le da la vía limpia y auditable (`sudo`) para ejercer el que ya tiene. Negárselo no haría a `deploy` menos poderoso; solo lo empujaría a escalar por el daemon de Docker, sin el rastro de `sudo`.

### Por qué hay que verificar el break-glass ANTES de cerrar `root`

El orden de cierre se apoya en una premisa: existe una **red de rescate** por si la clave nueva falla justo cuando ya se tapió `root`. Esa red es el **Rescue System del proveedor** —en Hetzner, un Linux mínimo que arranca **en RAM** con su propia credencial de `root` (Hetzner la genera al activarlo, mostrada en el panel), independiente de las cuentas del sistema instalado—. Entrás por SSH al entorno de rescate, montás el disco y reparás `authorized_keys`/`sshd_config`/`sudoers`. Es la red de rescate correcta **precisamente porque `root` queda bloqueada**: el gate de aceptación (`verify.sh` exige `passwd -S root` = `L`, y Lynis premia lo mismo) y `deploy` con `lock_passwd: true` dejan al sistema sin ninguna cuenta con contraseña. La consola web (VNC) del proveedor sirve para **observar** el arranque fuera de SSH, pero con las cuentas bloqueadas **no** podés loguearte en su prompt: no es el break-glass, el Rescue System sí.

Por eso, **antes** del endurecimiento de SSH, hay un paso explícito que confirma que tenés acceso al panel/API del proveedor para **activar el Rescue System** y que conocés el flujo (activar rescue → reboot → SSH a la credencial temporal). Esas credenciales del panel/API se guardan **off-site** (fuera del laptop del operador y fuera del propio servidor). Misma regla madre del doc: nunca cierres una vía sin haber confirmado la que la reemplaza —y el Rescue System es la vía que reemplaza a SSH cuando SSH no está y todas las cuentas están bloqueadas.

### Por qué el endurecimiento de kernel (`sysctl`) va DESPUÉS de Docker

Endurecer la pila de red del kernel (anti-spoofing, `syncookies`, bloqueo de ICMP redirects y source routing, `log_martians`) y reducir fugas de información (`dmesg_restrict`, `kptr_restrict`, `suid_dumpable`) es barato y de alto valor. Pero hay parámetros que **no** se tocan: `net.ipv4.ip_forward` (y el `bridge-netfilter`) son **propiedad de Docker**. El daemon los fija en arranque porque la red bridge y, sobre todo, la red **overlay del Swarm** necesitan forwarding. Un baseline CIS genérico que ponga `ip_forward=0` de forma persistente rompe el plano de datos de los contenedores tras el primer reboot, de manera silenciosa y dependiente del orden de arranque. De ahí dos reglas: el drop-in de `sysctl` se aplica **después** de instalar Docker, y **excluye** `ip_forward` y `bridge-nf-call`; tras aplicarlo se **verifica que el plano de datos sigue vivo** (un contenedor de prueba y la red overlay alcanzable).

### Por qué el firewall solo abre SSH

El firewall deja entrar un único puerto, el 22, y cierra todo lo demás, aunque la máquina sirva HTTP. La clave es por dónde entra ese HTTP: no por un puerto abierto sino por el [**Cloudflare Tunnel**](./05_how-to-exponer-cloudflare-tunnel.md), una conexión **saliente** del servidor hacia Cloudflare. El tráfico llega a Cloudflare y baja por ese túnel ya establecido; nunca toca un puerto entrante. El servidor solo necesita **egress** al puerto 7844 del borde de Cloudflare. Como no se publica ningún puerto de la app, no hay nada que abrir. El Swarm de un solo nodo tampoco abre sus puertos internos de clúster (2377/7946/4789): no hay otro nodo con quien hablar.

Matiz técnico: Docker administra `iptables` por su cuenta, y al publicar un puerto con `-p` inserta reglas que pueden **saltarse** las de `ufw` (crees el puerto cerrado por firewall y Docker lo dejó abierto). Aquí ese riesgo no se materializa porque **no se publica ningún puerto**: sin reglas de publicación de Docker, nada se salta a `ufw`, y la única vía entrante real es la que `ufw` controla, el 22.


---

## Camino verificado

El procedimiento ejecutado. **El orden importa.** Las claves y el `sudo` de `deploy` se instalan y se **verifican** (Paso 4), y el break-glass se confirma (Paso 7), **antes** de cerrar el acceso de `root` (Paso 8). Invertir ese orden te deja fuera del servidor (ver [Norma](#por-qué-el-orden-de-cierre-evita-el-autobloqueo)). Todos los comandos de abajo viven en `provision.sh`; aquí se documentan con su porqué.

### Paso 1 — Generar/identificar las claves en tu máquina local

Hay **dos** identidades autorizadas para `deploy`, con dos políticas de protección distintas (ver [Norma](#dos-claves-para-deploy-la-del-operador-humano-y-la-de-ci)).

**Clave del operador humano — CON passphrase, vía `ssh-agent`.** En tu máquina local (no en el servidor), una clave por persona y por host:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_${APP} -C "<persona>@<host-operador>"
```

`ssh-keygen` te pedirá una passphrase: **ponela** (no la dejes vacía). Cárgala en el agente para no teclearla en cada conexión:

```bash
ssh-add ~/.ssh/id_ed25519_${APP}
```

Para evitar el autobloqueo por `MaxAuthTries` (el agente ofrece todas tus claves antes de la correcta y agota los intentos), fija en `~/.ssh/config` que para este host se ofrezca **solo** esta identidad:

```
Host <IP-o-host>
  User deploy
  IdentityFile ~/.ssh/id_ed25519_${APP}
  IdentitiesOnly yes
```

**Clave de CI / deploy automático — SIN passphrase, como secret del repo.** El pipeline corre desatendido y no puede responder a un prompt de passphrase. Generá la clave sin passphrase y guardá la **privada** como secret del repositorio (p. ej. `SSH_DEPLOY_KEY` en GitHub Actions), nunca en disco plano ni en `git`:

```bash
ssh-keygen -t ed25519 -f ./ci_deploy_key -N "" -C "ci-deploy@${APP}"
```

En ambos casos la clave **privada nunca se copia al servidor**: al servidor solo van las **públicas** (`.pub`). La privada del operador vive cifrada en su laptop; la de CI vive en el almacén de secrets.

### Paso 2 — Instalar las claves públicas en `authorized_keys` (idempotente)

No uses `ssh-copy-id`: con una cuenta `--disabled-password` no hay contraseña contra la cual autenticarse, así que la copia asistida falla. Instala las claves a mano desde la sesión `root`.

Crea el directorio `.ssh` de `deploy` (idempotente: `install -d` no falla si ya existe):

```bash
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
touch /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
```

Agrega **cada** clave pública (la del operador y la de CI) con un guard idempotente: `grep -qxF` comprueba la línea exacta y solo hace `append` (`>>`) si falta. Así re-ejecutar el aprovisionamiento no duplica líneas ni pisa claves de otras personas:

```bash
add_key() {
  local key="$1" file=/home/deploy/.ssh/authorized_keys
  grep -qxF "$key" "$file" || echo "$key" >> "$file"
}
add_key 'ssh-ed25519 AAAA... <persona>@<host-operador>'
add_key 'ssh-ed25519 AAAA... ci-deploy@${APP}'
```

> **Nunca uses `>` (sobrescribir) sobre `authorized_keys`.** En un modelo multi-operador, `>` borra las claves de todos los demás de un saque. El `append` idempotente (`grep -qxF || >>`) es lo que permite agregar una persona, rotar una clave o dar de baja a alguien tocando **una sola línea**. La rotación/offboarding es: editar el archivo y borrar exactamente la línea de esa identidad.

Confirma los permisos y la propiedad:

```bash
ls -la /home/deploy/.ssh
```

`.ssh` debe quedar `drwx------ deploy deploy` y `authorized_keys`, `-rw------- deploy deploy`. SSH rechaza las claves si estos permisos son más laxos.

### Paso 3 — Conceder `sudo` a `deploy`

`deploy` se creó `--disabled-password` y sin `sudo`. Como la cuenta no tiene contraseña, sumarla al grupo `sudo` normal le pediría una contraseña inexistente: usa una regla `NOPASSWD` en un archivo propio de `sudoers.d` (el porqué, en la [Norma](#por-qué-nopasswd-con-una-cuenta---disabled-password)). Ten claro lo que concedés: `NOPASSWD:ALL` es **administración total del host**, no un permiso acotado (ver [Norma](#por-qué-nopasswd-con-una-cuenta---disabled-password)).

```bash
printf 'deploy ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-deploy
chmod 440 /etc/sudoers.d/90-deploy
visudo -cf /etc/sudoers.d/90-deploy
```

`visudo -cf` debe responder `parsed OK`. Valida siempre el archivo antes de confiar en él: una sintaxis rota en `sudoers` puede dejar el sistema sin `sudo`.

Verifica los privilegios efectivos:

```bash
sudo -l -U deploy
```

Debe listar `(ALL) NOPASSWD: ALL`.

### Paso 4 — Verificar el acceso de `deploy` (no te saltes este paso)

> **Esta es la barrera de seguridad de todo el procedimiento.** No avances al hardening (Paso 8) hasta confirmar, en esta sesión, que `deploy` entra con la clave del operador y puede hacer `sudo`. Si algo falla, todavía tienes la sesión `root` abierta para corregirlo.

**En tu máquina local**, abre una sesión como `deploy` con la clave del operador (ya cargada en `ssh-agent`; deja la sesión `root` abierta en otra terminal):

```bash
ssh deploy@<IP-o-host>
```

Con el `~/.ssh/config` del Paso 1 (`IdentityFile` + `IdentitiesOnly yes`), SSH ofrece solo la clave del operador y la passphrase la resuelve el agente. La sesión debe abrir como `deploy`. Ya dentro, comprueba el `sudo` y el acceso al Swarm:

```bash
sudo whoami
docker node ls
```

`sudo whoami` debe devolver `root`. `docker node ls` debe mostrar el nodo como `Ready` y con rol `Leader` —`deploy` opera Docker sin `sudo` porque está en el grupo `docker`—. Si las tres cosas funcionan, el acceso nuevo está confirmado y puedes cerrar el viejo.

### Paso 5 — Configurar el firewall con `ufw`

Cierra todo el tráfico entrante salvo SSH: no hace falta abrir ningún puerto de la aplicación ni los puertos internos del Swarm de un solo nodo (el porqué, en la [Norma](#por-qué-el-firewall-solo-abre-ssh)).

**Verifica IPv6 ANTES de activar `ufw`.** Los VPS modernos traen IPv6 por defecto. `ufw` solo filtra IPv6 si `IPV6=yes` en `/etc/default/ufw`; si estuviera en `no`, `ufw` gestiona solo `iptables` y deja `ip6tables` **sin tocar**: el puerto 22 (y cualquier otro) queda **abierto por IPv6 de forma silenciosa**, aunque `ufw status` se vea limpio. Confírmalo como `root`:

```bash
grep '^IPV6=' /etc/default/ufw
```

Debe imprimir `IPV6=yes`. Si imprime `IPV6=no`, corrígelo a `yes` antes de continuar.

**Como `root`:**

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw --force enable
```

Verifica el estado:

```bash
ufw status verbose
```

Debe indicar `Status: active`, política `deny (incoming)` / `allow (outgoing)`, y la regla `22/tcp` **dos veces**: `22/tcp ALLOW IN Anywhere` (IPv4) y `22/tcp (v6) ALLOW IN Anywhere (v6)` (IPv6). Si la línea `(v6)` no aparece, IPv6 quedó sin proteger: vuelve a `IPV6=yes` y `ufw --force reset` + reaplica.

> **Egress abierto, decisión consciente.** `default allow outgoing` deja salir todo a propósito. Para este nodo único, acotar el egress fino iría contra el dial robusto-no-es-máximo. Lo único que el nodo necesita afuera es el túnel de Cloudflare (7844), DNS (53), `apt` (80/443) y el registry de imágenes (443). Una allowlist de egress sería una variante para clientes con exigencia de cumplimiento, no el camino base.
>
> **Swarm multi-nodo (no aplica aquí).** El Swarm de un solo nodo no abre `2377/7946/4789` porque no hay peer con quien hablar. Si algún día se suma un segundo nodo, esos puertos se abren **solo al peer** (no a `0.0.0.0/0`), porque `7946`/`4789` escuchan en todas las interfaces por defecto.
>
> **Sinergia con el firewall de borde.** `ufw` corre **dentro** del host, y Docker puede saltárselo insertando reglas en `iptables` al publicar un puerto con `-p` (ver [Norma](#por-qué-el-firewall-solo-abre-ssh)). El firewall de borde del proveedor (Hetzner Cloud Firewall), que vive **fuera** del host, es la red que Docker no puede tocar: el verdadero backstop ante un `docker run -p` o un `ports:` accidental. El borde se configura en el aprovisionamiento (doc 03); aquí basta saber que `ufw` no es la única capa.

### Paso 6 — Instalar y configurar `fail2ban`

Instala `fail2ban` para banear las IP que acumulen intentos fallidos de SSH:

```bash
apt-get install -y fail2ban
```

En las versiones actuales de Ubuntu los registros de SSH van al *journal* de `systemd`, no a `/var/log/auth.log`; por eso el jail lee del *journal* con `backend = systemd`. Crea `/etc/fail2ban/jail.local`:

```ini
[DEFAULT]
backend = systemd
# El propio operador y la red de administración NUNCA se banean:
ignoreip = 127.0.0.1/8 ::1 <CIDR-admin>
bantime  = 1h
# Backoff exponencial: el reincidente acumula bans cada vez más largos.
bantime.increment = true
findtime = 10m
maxretry = 5
# Banear a nivel nftables (Ubuntu actual usa nft, no iptables legacy):
banaction = nftables-multiport

[sshd]
enabled = true
port    = 22
```

`ignoreip` es la defensa directa contra el **auto-ban del operador**: con auth solo-por-clave, un `ssh` con la identidad equivocada o un job de CI que erra acumula 5 fallos y se auto-banea a nivel firewall, dejándote fuera igual que el autobloqueo de SSH. El loopback y el CIDR de administración quedan exentos. Si tu IP de oficina es dinámica y no tenés un CIDR estable, dejá solo loopback y compensá con el runbook de des-baneo (abajo); ante un lockout total, el break-glass es el Rescue System (Paso 7).

Habilita el servicio y aplícalo con `restart` (NO `reload`): en una instalación fresca el paquete ya arrancó con su config por defecto y el `reload` **no** re-ejecuta el `actionstart` de la acción `nftables`, así que la tabla `f2b-table` nunca se crea y el ban no llega a `nft`. El `restart` reinicializa la acción:

```bash
systemctl enable fail2ban
systemctl restart fail2ban
```

Verifica que esté activo y vigilando SSH:

```bash
systemctl is-active fail2ban
fail2ban-client status sshd
```

`systemctl is-active` debe devolver `active`, y `fail2ban-client status sshd` debe mostrar el jail `sshd` en funcionamiento.

**Verificación FUNCIONAL del ban (no basta con que el jail esté `running`).** Un jail puede figurar como `running` y no banear nunca, si el `banaction` no matchea el firewall real (p. ej. `backend systemd` con un `banaction` que escribe en `iptables` legacy mientras el host usa `nft`). Comprueba que el baneo **llega al firewall**: banea una IP de descarte, confírmala en `nft`, y des-banéala:

```bash
fail2ban-client set sshd banip 203.0.113.7
nft list ruleset | grep 203.0.113.7
fail2ban-client set sshd unbanip 203.0.113.7
```

La IP de prueba debe aparecer en el set de `nft` tras el `banip` y desaparecer tras el `unbanip`. Si **no** aparece, el `banaction` no está actuando: confirma `banaction = nftables-multiport` y reinicia con `systemctl restart fail2ban` (un `reload` no reinicializa la acción `nftables` sobre una config recién escrita — por eso el `restart`).

> **Runbook de des-baneo.** Si una IP legítima quedó baneada: `fail2ban-client set sshd unbanip <IP>` y confirma con `fail2ban-client status sshd`. Si te baneaste a vos mismo y perdiste SSH, reconectá **desde otra IP** (hotspot, VPN) y corré el `unbanip`, o esperá a que expire el `bantime`. Si además perdiste toda vía de acceso, el break-glass es el **Rescue System** del proveedor (Paso 7); la VNC no sirve acá porque las cuentas están bloqueadas.
>
> **Alcance: SOLO el puerto 22.** `fail2ban` aquí cubre **únicamente** la fuerza bruta sobre SSH. No es un WAF ni defensa de capa de aplicación: el tráfico HTTP entra por el túnel de Cloudflare, así que la defensa app-layer (rate limiting, reglas WAF) es responsabilidad de Cloudflare, no de `fail2ban`.

### Paso 7 — Confirmar el break-glass (antes de cerrar `root`)

> **No cierres `root` sin tener confirmado el Rescue System del proveedor.** Este paso convierte la "red de rescate" de suposición en algo confirmado (el porqué, en la [Norma](#por-qué-hay-que-verificar-el-break-glass-antes-de-cerrar-root)).

El break-glass de este modelo es el **Rescue System** del proveedor, **no** una contraseña de `root` en la consola: `root` queda **bloqueada** (lo exige `verify.sh` y lo premia Lynis) y `deploy` tiene `lock_passwd: true`, así que el sistema instalado no tiene ninguna cuenta con contraseña para el prompt de la VNC. Fijar una contraseña de `root` para la consola **rompería el gate** (`passwd -S root` pasaría a `P` y `verify.sh` daría FAIL). Antes de tapiar SSH-`root`, confirma la vía de rescate que sí funciona:

1. **Confirma acceso al panel/API del proveedor** con permiso para activar el Rescue System, y **guarda esas credenciales off-site** (gestor de secrets del equipo, fuera del laptop del operador y fuera del propio servidor). Ese acceso es el que sobrevive a un lockout total de SSH (clave rota, `ufw` mal, auto-ban de `fail2ban`).
2. **Ten claro el flujo del Rescue System** —Hetzner: *Rescue* → activar (Hetzner genera una contraseña de `root` temporal para el entorno de rescate) → *Reset*/reboot → `ssh root@<ip>` al Linux en RAM → montás el disco y reparás `authorized_keys`/`sshd_config`/`sudoers`—. La credencial de rescate es efímera y la emite el panel en cada activación: no hay nada que fijar ni guardar en el servidor.
3. (Opcional) La **consola web (VNC)** sirve para **observar** el arranque fuera de SSH, pero con las cuentas bloqueadas no vas a poder loguearte en su prompt; para reparar de verdad, el camino es el Rescue System.

Solo con el acceso al panel/API confirmado y guardado off-site, avanza al hardening.

### Paso 8 — Endurecer SSH

Solo ahora, con el acceso de `deploy` confirmado (Paso 4) y el break-glass probado (Paso 7), cierra el login de `root` y la autenticación por contraseña. No edites el `sshd_config` principal: usa un *drop-in*, que el servicio ya incluye con `Include /etc/ssh/sshd_config.d/*.conf`.

**Cuidado con la precedencia de drop-ins.** Las imágenes cloud de Ubuntu traen `/etc/ssh/sshd_config.d/50-cloud-init.conf` con `PasswordAuthentication yes`. En `sshd_config` **gana el primer valor leído** por cada keyword, y los drop-ins se incluyen en **orden alfanumérico**: `50-` se lee **antes** que `99-`, así que el `yes` del cloud-init le ganaría a tu `no` y el password auth quedaría **activo** mientras crees haberlo cerrado. Hay dos formas de garantizar la precedencia; elige una:

- **(a) Neutralizar el drop-in de cloud-init**: vacía `/etc/ssh/sshd_config.d/50-cloud-init.conf` (o reafirma ahí los valores endurecidos), o
- **(b) Nombrar el hardening con prefijo menor** para que se lea primero: usar `00-hardening.conf` en lugar de `99-hardening.conf`.

Crea el drop-in de hardening (aquí, opción (b), `00-hardening.conf`):

```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers deploy
MaxAuthTries 3
LoginGraceTime 20
```

`AllowUsers deploy` es la traducción literal del modelo ("acotar **quién** puede ser `deploy`"): deny-by-default a nivel de identidad, solo `deploy` puede siquiera intentar autenticarse. `MaxAuthTries 3` y `LoginGraceTime 20` reducen la ventana de fuerza bruta y refuerzan a `fail2ban` (por eso el `~/.ssh/config` del operador con `IdentitiesOnly yes` del Paso 1 es obligatorio: sin él, el agente ofrece varias claves y agota los 3 intentos contra tu propio server).

> **No pinear `Ciphers`/`MACs`/`KexAlgorithms` es deliberado.** OpenSSH de Ubuntu LTS ya trae defaults modernos y seguros; fijar listas de algoritmos agrega mantenimiento y riesgo de lockout/incompatibilidad en cada upgrade de OpenSSH sin ganancia real para un nodo único. Es una omisión consciente del dial robusto-no-es-máximo, no un olvido.

Valida la configuración y, solo si pasa, recarga el servicio:

```bash
sshd -t
systemctl reload ssh
```

**Verifica los valores EFECTIVOS, no solo la sintaxis.** `sshd -t` valida que el archivo parsea, pero **no** te dice qué valor ganó tras resolver todos los drop-ins: pasaría `OK` aunque el `50-cloud-init.conf` te esté venciendo. Comprueba la configuración resuelta con `sshd -T`:

```bash
sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication|kbdinteractiveauthentication|allowusers|maxauthtries|logingracetime)'
```

Debe mostrar `passwordauthentication no`, `permitrootlogin no`, `pubkeyauthentication yes`, `allowusers deploy`, `maxauthtries 3`, `logingracetime 20`. Si `passwordauthentication` sale `yes`, la precedencia del cloud-init te ganó: vuelve a la opción (a) o (b) de arriba. `systemctl reload ssh` aplica el cambio sin cortar las sesiones abiertas.

### Paso 9 — Endurecer la pila de red del kernel (`sysctl`) — DESPUÉS de Docker

Con Docker ya instalado (doc 03), aplica el endurecimiento `sysctl`. El orden importa: este drop-in se aplica **después** de Docker y **excluye** los parámetros que Docker administra (el porqué, en la [Norma](#por-qué-el-endurecimiento-de-kernel-sysctl-va-después-de-docker)).

Crea `/etc/sysctl.d/99-hardening.conf`:

```ini
# Anti-spoofing y robustez TCP (CIS L1, red)
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# Reducción de fugas de información (CIS L1, info-leak)
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
fs.suid_dumpable = 0
```

> **No incluyas `net.ipv4.ip_forward` ni `net.bridge.bridge-nf-call-*`.** Son propiedad de Docker: la red bridge y la overlay del Swarm necesitan forwarding, y un `ip_forward=0` persistente rompe el plano de datos de los contenedores tras el reboot. Déjalos gestionados por Docker.

Aplica el drop-in:

```bash
sysctl --system
```

**Verifica que el plano de datos de Swarm sigue vivo** (el endurecimiento no debe haber roto el networking de contenedores):

```bash
sysctl net.ipv4.conf.all.rp_filter        # debe ser 1
docker run --rm hello-world                # el contenedor sale a la red y corre
docker node ls                             # el nodo sigue Ready / Leader
```

Si algún `docker service` con red overlay deja de ser alcanzable tras este paso, revisa que no se haya colado un `ip_forward=0` en `/etc/sysctl.d/`.

Verifica también que AppArmor —de lo que depende el perfil `docker-default` que confina los contenedores— sigue activo:

```bash
aa-status
```

Debe reportar el módulo cargado y perfiles en modo `enforce`. No escribas perfiles propios: sería sobre-endurecer para este dial.

### Paso 10 — Verificación final del acceso

Confirma que el acceso nuevo sigue vivo y que el viejo quedó cerrado.

**En tu máquina local**, comprueba que `deploy` entra (con la clave del operador, vía agente) y escala a `root`:

```bash
ssh deploy@<IP-o-host>
sudo whoami
```

Y que `root` ya no puede entrar por SSH:

```bash
ssh root@<IP-o-host>
```

El intento como `root` debe terminar en `Permission denied (publickey)`. Con eso, el único modo de entrar al servidor es una clave autorizada de `deploy`.

A partir de aquí, tu conexión habitual al servidor es simplemente:

```bash
ssh deploy@<IP-o-host>
```

(el `~/.ssh/config` del Paso 1 ya resuelve `User`, `IdentityFile` e `IdentitiesOnly`).

### Paso 11 — Auditoría independiente y reporte off-host

La verificación de los pasos anteriores es **auto-atestación**: prueba que cada control que pensaste aplicar quedó aplicado, pero no detecta lo que el procedimiento no contempló. Cierra con una auditoría **independiente** y evidencia fechada fuera del host.

Corre `verify.sh` (las post-condiciones codificadas: `ufw status`, `sshd -T` efectivo, `passwd -S root` bloqueada, `fail2ban-client status sshd` + ban funcional en `nft`, rotación de logs de Docker, Swarm activo, `deploy` en el grupo docker, timers habilitados) y luego un escaneo de Lynis como gate:

```bash
./verify.sh
apt-get install -y lynis
lynis audit system
```

Define un umbral de aceptación explícito: **Hardening Index ≥ 70** y **cero warnings** en SSH, firewall y auth. Las suppressions de warnings que el dial decide no atender (p. ej. no pinear ciphers) se documentan con su justificación, no se ignoran en silencio.

> **Falso positivo conocido en Ubuntu 26.04 — `PKGS-7388`.** Lynis 3.1.6 reporta "Can't find any security repository" aunque el repo `*-security` **sí** existe: en Ubuntu 26.04 vive en formato **deb822** (`/etc/apt/sources.list.d/ubuntu.sources`), que esa prueba de Lynis no parsea. Es una suppression **justificada**, no un hallazgo: confírmalo con `grep -r security /etc/apt/sources.list.d/ubuntu.sources` y documentá la excepción para que no confunda la lectura del Hardening Index.

Guarda el reporte —`verify.sh` con timestamp y PASS/FAIL, más el resumen de Lynis— **off-host**, en la máquina del operador o el almacén del equipo (igual que la passphrase de restic y las credenciales del panel/API de rescate): el estado del nodo se atestigua con evidencia retenida fuera del nodo, no con un OK en pantalla que se pierde al cerrar la sesión.

> Re-auditá periódicamente (Lynis cada tanto): `unattended-upgrades` cambia paquetes con el tiempo y la postura puede derivar. La auditoría no es un evento único del aprovisionamiento.

---

## Lo que sigue

Con el acceso cerrado y el firewall dejando entrar solo SSH, el siguiente objetivo es **publicar la aplicación** sin reabrir puertos: exponerla por un Cloudflare Tunnel saliente, aprovisionado desde la API.

- [Exponer la app por Cloudflare Tunnel](./05_how-to-exponer-cloudflare-tunnel.md)
