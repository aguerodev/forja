#!/usr/bin/env bash
#
# provision.sh — Aprovisionamiento idempotente de un nodo Swarm de un solo nodo.
#
# FUENTE DE VERDAD del aprovisionamiento. Los documentos 03 (aprovisionar) y
# 04 (endurecer acceso) explican el PORQUE de cada decision; este script es el
# QUE se ejecuta. Si divergen, gana el script y se actualiza el .md.
#
# Doctrina:
#   - Idempotente: re-ejecutar no rompe ni duplica. Cada fase tiene su guard.
#   - Cada control se verifica por su EFECTO, nunca por su mera existencia
#     (eso vive en verify.sh, el gate de aceptacion).
#   - Robusto, no maximo: lo que la revision marco como DIAL queda como omision
#     consciente documentada, no se implementa aqui (ver NOTAS al final).
#
# Cobertura (fases del protocolo §2 ejecutables sobre el host):
#   Fase 2  — apt full-upgrade, timezone/NTP, swap, journald, auto-reboot.
#   Fase 3  — ufw (v4 + v6) con default deny incoming.
#   Fase 7  — daemon.json con rotacion de logs, Docker pineado, swarm init local.
#   Fase 6  — sysctl L1 DESPUES de Docker (excluye ip_forward).
#   Fase 4/10 — fail2ban con ignoreip + banaction nftables.
#
# Lo que NO hace este script (vive antes/aparte, ver docs):
#   - Fase 0 (Hetzner Cloud Firewall, server sin password root, Backups, cloud-init):
#     se hace en la consola/API del proveedor ANTES del primer boot. Ver user_data.yaml.
#   - Creacion del usuario deploy y su authorized_keys: lo hace cloud-init (user_data.yaml).
#
# Lo que SI hace (ojo): la Fase 5 aplica el cierre EFECTIVO de SSH root/password
#   (PermitRootLogin no, PasswordAuthentication no, AllowUsers deploy) y recarga sshd.
#   Usa 'reload' (no 'restart') para no cortar la sesion viva de una corrida manual,
#   pero la politica efectiva cambia: nuevos logins de root/password quedan cerrados.
#   Antes de recargar valida que 'deploy' exista con authorized_keys no vacio; si no,
#   ABORTA (evita autobloqueo). El cierre base tambien viene de cloud-init en el boot.
#
# Uso:
#   sudo APP=miapp TIMEZONE=UTC ./provision.sh
#
# Requisitos: Ubuntu LTS / derivado Debian (ID_LIKE=debian), ejecutado como root.

set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────
# Configuracion (placeholders — sin datos de ningun server real).
# Sobreescribibles por variable de entorno: APP=miapp ./provision.sh
# ────────────────────────────────────────────────────────────────────────────
APP="${APP:-app}"                                   # nombre logico de la app/agencia
DEPLOY_USER="${DEPLOY_USER:-deploy}"                # cuenta operativa (la crea cloud-init)
TIMEZONE="${TIMEZONE:-UTC}"                         # reloj base: fail2ban/timers/RPO dependen de el
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"                # swapfile modesto (anti-OOM en nodo unico)
SWAPPINESS="${SWAPPINESS:-10}"                      # preferir RAM, usar swap solo bajo presion
JOURNALD_MAX="${JOURNALD_MAX:-500M}"                # tope de journal persistente (fail2ban lee de aqui)
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-04:00}"       # ventana de reinicio tras parche de kernel
SSH_PORT="${SSH_PORT:-22}"                          # puerto SSH (unico inbound de host)
DOCKER_LOG_MAX_SIZE="${DOCKER_LOG_MAX_SIZE:-10m}"   # rotacion json-file: tope por archivo
DOCKER_LOG_MAX_FILE="${DOCKER_LOG_MAX_FILE:-3}"     # rotacion json-file: cantidad de archivos
SWARM_LISTEN_ADDR="${SWARM_LISTEN_ADDR:-127.0.0.1}" # gestion del Swarm NO se expone en nodo unico
# Pin de Docker Engine: NUNCA latest flotante (drift entre servers de la flota).
# Formato APT: "<version>" como la reporta `apt-cache madison docker-ce`.
# Vacio => el script aborta pidiendo un pin explicito (decision consciente).
DOCKER_CE_VERSION="${DOCKER_CE_VERSION:-}"          # ej: 5:27.5.1-1~ubuntu.24.04~noble
# CIDR del operador/agencia para que fail2ban NUNCA banee tu propia salida.
# Vacio => solo loopback en ignoreip (el operador asume el riesgo de auto-baneo).
ADMIN_CIDR="${ADMIN_CIDR:-}"                        # ej: 203.0.113.0/24  (placeholder)

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_SUSPEND=1

# ────────────────────────────────────────────────────────────────────────────
# Utilidades
# ────────────────────────────────────────────────────────────────────────────
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "Ejecutalo como root (sudo)."; }

# Escribe contenido a un archivo solo si difiere (idempotencia + no toca mtime en vano).
write_if_changed() {
  local path="$1"; local content="$2"
  if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
    return 1   # sin cambios
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  return 0     # cambiado
}

# ────────────────────────────────────────────────────────────────────────────
# Fase 2 — Estado base del SO
# ────────────────────────────────────────────────────────────────────────────

phase_apt_full_upgrade() {
  log "Fase 2 — apt full-upgrade (no 'upgrade': no retener transiciones de kernel)"
  apt-get update -y
  # full-upgrade resuelve cambios de dependencias que 'upgrade' deja en hold.
  apt-get full-upgrade -y
  # Si un paquete (tipicamente el kernel) pide reinicio, este script NO reinicia
  # solo: deja el flag y lo reporta. El reinicio lo decide el operador o el
  # auto-reboot desatendido (mas abajo). Reiniciar a mitad de provision cortaria
  # la corrida; verify.sh y el operador validan el kernel activo despues.
  if [[ -f /var/run/reboot-required ]]; then
    warn "Hay reinicio pendiente (kernel nuevo). Reinicia el host y re-ejecuta provision.sh."
  fi
}

phase_timezone_ntp() {
  log "Fase 2 — timezone (${TIMEZONE}) + NTP (timesyncd; NO chrony, es DIAL)"
  timedatectl set-timezone "${TIMEZONE}"
  timedatectl set-ntp true
  # Verificacion por efecto: el reloj debe estar realmente sincronizado.
  # No es instantaneo tras set-ntp; reintenta unos segundos sin abortar.
  local i
  for i in 1 2 3 4 5 6; do
    if timedatectl show -p NTPSynchronized --value | grep -q '^yes$'; then
      break
    fi
    sleep 5
  done
  timedatectl show -p NTPSynchronized --value | grep -q '^yes$' \
    || warn "NTPSynchronized aun en 'no'; revisa salida a NTP (UDP 123)."
}

phase_swap() {
  log "Fase 2 — swapfile ${SWAP_SIZE_MB}MB + vm.swappiness=${SWAPPINESS} (anti-OOM)"
  # Guard idempotente: si ya hay swap activo, no recrear.
  if swapon --show=NAME --noheadings | grep -q .; then
    log "  swap ya activo; omito creacion."
  else
    local swapfile=/swapfile
    if [[ ! -f "$swapfile" ]]; then
      # fallocate es instantaneo; si el FS no lo soporta, cae a dd.
      fallocate -l "${SWAP_SIZE_MB}M" "$swapfile" \
        || dd if=/dev/zero of="$swapfile" bs=1M count="${SWAP_SIZE_MB}" status=none
    fi
    chmod 600 "$swapfile"
    mkswap "$swapfile" >/dev/null
    swapon "$swapfile"
    # Persistir en fstab solo si no esta ya.
    grep -qxF "${swapfile} none swap sw 0 0" /etc/fstab \
      || printf '%s none swap sw 0 0\n' "$swapfile" >> /etc/fstab
  fi
  write_if_changed /etc/sysctl.d/99-swappiness.conf "vm.swappiness=${SWAPPINESS}" \
    && sysctl -q vm.swappiness="${SWAPPINESS}" || true
}

phase_journald() {
  log "Fase 2 — journald persistente y capeado (${JOURNALD_MAX})"
  # fail2ban usa backend=systemd: un journal volatil pierde el historial de bans
  # tras reboot, y sin cota compite por disco con los logs de Docker (que si estan capeados).
  local conf
  conf=$(cat <<EOF
[Journal]
Storage=persistent
SystemMaxUse=${JOURNALD_MAX}
EOF
)
  if write_if_changed /etc/systemd/journald.conf.d/00-limits.conf "$conf"; then
    systemctl restart systemd-journald
  fi
}

phase_unattended_upgrades() {
  log "Fase 2 — unattended-upgrades + auto-reboot ${AUTO_REBOOT_TIME} (kernel parcheado SE reinicia)"
  apt-get install -y unattended-upgrades
  # Activacion del ciclo periodico.
  write_if_changed /etc/apt/apt.conf.d/20auto-upgrades "$(cat <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
)" || true
  # Corrige la contradiccion critica de 03: sin esto, el parche de kernel queda
  # instalado en disco y el host corre el kernel viejo VULNERABLE indefinidamente.
  # El servicio vuelve solo tras el reinicio (Swarm + restart policy + tunel reconectan).
  write_if_changed /etc/apt/apt.conf.d/51auto-reboot "$(cat <<EOF
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${AUTO_REBOOT_TIME}";
EOF
)" || true
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
}

# ────────────────────────────────────────────────────────────────────────────
# Fase 3 — Firewall de host (ufw)
# ────────────────────────────────────────────────────────────────────────────

phase_ufw() {
  log "Fase 3 — ufw deny incoming, allow ${SSH_PORT}/tcp (v4 + v6)"
  apt-get install -y ufw
  # CRITICO: si IPV6=no, ufw deja ip6tables sin tocar y el puerto entra por IPv6
  # con `ufw status` viendose limpio. Forzar IPV6=yes ANTES de enable.
  if grep -q '^IPV6=' /etc/default/ufw; then
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  else
    printf 'IPV6=yes\n' >> /etc/default/ufw
  fi
  ufw default deny incoming
  ufw default allow outgoing
  # Egress queda ABIERTO por decision del dial (destinos reales: 7844 Cloudflare,
  # DNS 53, apt 80/443, registry 443). Allowlist fina de egress es DIAL, no se aplica.
  ufw allow "${SSH_PORT}/tcp" comment 'SSH'
  ufw --force enable
}

# ────────────────────────────────────────────────────────────────────────────
# Fase 7 — Docker / Swarm
# ────────────────────────────────────────────────────────────────────────────

phase_docker_daemon_json() {
  log "Fase 7 — /etc/docker/daemon.json con rotacion de logs (ANTES de levantar servicios)"
  # CRITICO: el driver default json-file NO rota -> /var/lib/docker se llena y
  # tumba el nodo (modo de muerte mas probable). NO 'live-restore' (Swarm lo ignora).
  local conf
  conf=$(cat <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_MAX_SIZE}",
    "max-file": "${DOCKER_LOG_MAX_FILE}"
  }
}
EOF
)
  if write_if_changed /etc/docker/daemon.json "$conf"; then
    # Solo reiniciar si Docker ya esta instalado; si no, se instala despues con la config ya puesta.
    systemctl is-active --quiet docker && systemctl restart docker || true
  fi
}

phase_docker_install() {
  log "Fase 7 — instalar Docker Engine PINEADO (nunca latest flotante)"
  [[ -n "${DOCKER_CE_VERSION}" ]] \
    || die "DOCKER_CE_VERSION vacio. Pasa un pin explicito (apt-cache madison docker-ce). NUNCA latest."
  if command -v docker >/dev/null 2>&1; then
    log "  docker ya presente ($(docker --version)); omito instalacion."
  else
    # Repo APT oficial (no 'curl | sh', que instala latest flotante).
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    local codename
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
    write_if_changed /etc/apt/sources.list.d/docker.list \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" || true
    apt-get update -y
    apt-get install -y \
      "docker-ce=${DOCKER_CE_VERSION}" \
      "docker-ce-cli=${DOCKER_CE_VERSION}" \
      containerd.io docker-buildx-plugin docker-compose-plugin
    # Hold para que un apt upgrade no corra la version sin querer.
    apt-mark hold docker-ce docker-ce-cli
  fi
  systemctl enable --now docker
}

phase_swarm_init() {
  log "Fase 7 — docker swarm init --listen-addr ${SWARM_LISTEN_ADDR} (gestion NO expuesta)"
  # Guard idempotente: el init default abre 2377/7946/4789 en la IP publica antes
  # del firewall; acotar la gestion a loopback en nodo unico.
  if docker info 2>/dev/null | grep -q "Swarm: active"; then
    log "  Swarm ya activo; omito init."
  else
    docker swarm init --listen-addr "${SWARM_LISTEN_ADDR}:2377" --advertise-addr "${SWARM_LISTEN_ADDR}"
  fi
  # Nota multi-nodo (DIAL): si algun dia se suma un peer, abrir 2377/7946/4789 SOLO
  # hacia la IP privada del peer, nunca 0.0.0.0/0. No se implementa hoy.
}

phase_docker_smoke() {
  log "Fase 7 — smoke test del plano de datos de Docker"
  docker run --rm hello-world >/dev/null \
    || die "hello-world fallo: el plano de datos de Docker esta roto."
}

phase_deploy_docker_group() {
  log "Fase 7 — ${DEPLOY_USER} en el grupo docker (opera Docker sin sudo)"
  # user_data.yaml deja este paso a provision.sh a proposito (el grupo docker
  # no existe hasta instalar Docker). Sin esto, 'docker node ls' como ${DEPLOY_USER}
  # (doc 04 Paso 4) falla. Idempotente: solo agrega si falta.
  if ! getent passwd "${DEPLOY_USER}" >/dev/null 2>&1; then
    warn "usuario ${DEPLOY_USER} no existe todavia; omito el alta al grupo docker (lo crea cloud-init)."
    return 0
  fi
  if id -nG "${DEPLOY_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    log "  ${DEPLOY_USER} ya esta en el grupo docker; omito."
  else
    usermod -aG docker "${DEPLOY_USER}"
    log "  ${DEPLOY_USER} agregado al grupo docker (re-login para que tome efecto)."
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# Fase 6 — sysctl / kernel — DESPUES de Docker (orden deliberado)
# ────────────────────────────────────────────────────────────────────────────

phase_sysctl_hardening() {
  log "Fase 6 — sysctl L1 (red + info-leak), EXCLUYE ip_forward (propiedad de Docker)"
  # Aplicar DESPUES de Docker: incluir ip_forward=0 o tocar bridge-nf-call romperia
  # el networking de Swarm. Este baseline CIS L1 es de alto valor / costo cero.
  local conf
  conf=$(cat <<'EOF'
# Baseline CIS L1 — red e info-leak. NO incluye net.ipv4.ip_forward (Docker lo gestiona).
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
fs.suid_dumpable = 0
EOF
)
  if write_if_changed /etc/sysctl.d/99-hardening.conf "$conf"; then
    sysctl --system >/dev/null
  fi
  # Re-verificar el plano de Docker tras tocar sysctl.
  phase_docker_smoke
}

# ────────────────────────────────────────────────────────────────────────────
# Fase 4/10 — fail2ban (con ignoreip y verificacion funcional via verify.sh)
# ────────────────────────────────────────────────────────────────────────────

phase_fail2ban() {
  log "Fase 10 — fail2ban con ignoreip + banaction nftables (defiende SOLO puerto SSH)"
  apt-get install -y fail2ban
  # ignoreip evita el auto-baneo del operador. bantime.increment penaliza reincidentes.
  # banaction nftables-multiport: en hosts con nft, el iptables default puede no
  # matchear y el jail corre "running" sin banear nunca. fail2ban defiende SOLO el
  # puerto 22; la fuerza bruta a nivel app entra por el tunel saliente de Cloudflare
  # y es INVISIBLE aqui -> esa defensa es del WAF + Rate Limiting de Cloudflare.
  local ignoreip="127.0.0.1/8 ::1"
  [[ -n "${ADMIN_CIDR}" ]] && ignoreip="${ignoreip} ${ADMIN_CIDR}"
  local conf
  conf=$(cat <<EOF
[DEFAULT]
backend = systemd
banaction = nftables-multiport
ignoreip = ${ignoreip}
bantime = 1h
bantime.increment = true
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ${SSH_PORT}
EOF
)
  if write_if_changed /etc/fail2ban/jail.local "$conf"; then
    systemctl enable fail2ban >/dev/null 2>&1 || true
    # restart (NO reload) al (re)escribir jail.local: en una instalacion fresca
    # el 'reload' registra el ban en la DB pero NO ejecuta el actionstart de la
    # accion nftables, asi que la tabla inet f2b-table nunca se crea y el ban no
    # llega a nft (verify.sh: FAIL ban NO efectivo). El restart reinicializa la
    # accion. Verificado en Ubuntu 26.04 / fail2ban 1.1.0 / nftables 1.1.6.
    systemctl restart fail2ban
  else
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# Fase 5 — drop-in de hardening SSH (lo DEJA escrito; NO cierra la sesion viva)
# ────────────────────────────────────────────────────────────────────────────

phase_ssh_hardening_dropin() {
  log "Fase 5 — drop-in de hardening SSH (precedencia corregida) + verificacion sshd -T"

  # Guard anti-lockout: esta fase restringe el login a AllowUsers ${DEPLOY_USER} y
  # rechaza root/password. Si ${DEPLOY_USER} no existe o no tiene una clave util,
  # recargar sshd deja a TODOS afuera en el proximo reconnect. Fallar TEMPRANO.
  if ! getent passwd "${DEPLOY_USER}" >/dev/null 2>&1; then
    die "usuario ${DEPLOY_USER} no existe: aborto antes de cerrar SSH (evita lockout). Crealo (cloud-init/user_data.yaml) antes de endurecer."
  fi
  local _du_home
  _du_home="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
  if [[ ! -s "${_du_home}/.ssh/authorized_keys" ]]; then
    die "${DEPLOY_USER} no tiene ${_du_home}/.ssh/authorized_keys con contenido: aborto antes de cerrar SSH (evita lockout)."
  fi

  # CRITICO silencioso: por orden alfanumerico gana el PRIMER valor; 50-cloud-init.conf
  # (PasswordAuthentication yes) vence a 99-hardening.conf. Por eso el drop-in se
  # nombra 00-hardening.conf para ganar la precedencia, y se neutraliza el de cloud-init.
  local hardening
  hardening=$(cat <<EOF
# Hardening SSH — 00- para ganar precedencia sobre 50-cloud-init.conf.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers ${DEPLOY_USER}
MaxAuthTries 3
LoginGraceTime 20
EOF
)
  # NO se pinean Ciphers/MACs/Kex: decision deliberada (defaults de OpenSSH LTS son
  # seguros; pinear genera lockouts en upgrades). Es DIAL.
  write_if_changed /etc/ssh/sshd_config.d/00-hardening.conf "$hardening" || true

  # Neutralizar el drop-in de cloud-init si reabre password auth.
  local ci=/etc/ssh/sshd_config.d/50-cloud-init.conf
  if [[ -f "$ci" ]] && grep -qi '^[[:space:]]*PasswordAuthentication[[:space:]]\+yes' "$ci"; then
    sed -i 's/^[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/I' "$ci"
  fi

  # Verificar config EFECTIVA (sshd -T), no sintaxis (sshd -t da falso OK).
  sshd -t || die "sshd_config invalido; no recargo SSH."
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  sshd -T | grep -qi '^passwordauthentication no'   || die "PasswordAuthentication no NO efectivo."
  sshd -T | grep -qi '^permitrootlogin no'          || die "PermitRootLogin no NO efectivo."
  sshd -T | grep -qi "^allowusers ${DEPLOY_USER}"   || warn "AllowUsers ${DEPLOY_USER} no efectivo (revisa)."
}

# ────────────────────────────────────────────────────────────────────────────
# Orquestacion
# ────────────────────────────────────────────────────────────────────────────
main() {
  require_root
  log "Aprovisionando nodo para '${APP}' — idempotente, robusto-no-maximo."

  # Fase 2
  phase_apt_full_upgrade
  phase_timezone_ntp
  phase_swap
  phase_journald
  phase_unattended_upgrades

  # Fase 3
  phase_ufw

  # Fase 7 (daemon.json ANTES de levantar servicios)
  phase_docker_daemon_json
  phase_docker_install
  phase_swarm_init
  phase_docker_smoke
  phase_deploy_docker_group

  # Fase 6 (sysctl DESPUES de Docker)
  phase_sysctl_hardening

  # Fase 10
  phase_fail2ban

  # Fase 5 (drop-in: aplica y valida el cierre efectivo de root/password; guard anti-lockout)
  phase_ssh_hardening_dropin

  log "Provision OK. Ejecuta ./verify.sh para el gate de post-condiciones."
}

main "$@"
