#!/usr/bin/env bash
#
# verify.sh — Gate de aceptacion: post-condiciones del nodo aprovisionado.
#
# FUENTE DE VERDAD de "el server quedo bien". Sale ≠0 si CUALQUIER chequeo falla.
# Filosofia: cada control se valida por su EFECTO, no por su existencia.
#   - sshd -T (config efectiva), no sshd -t (solo sintaxis, da falso OK).
#   - ufw status active + regla v6 real, no solo "el paquete esta instalado".
#   - fail2ban: ban funcional (banip -> nft -> unbanip), no solo "running".
#
# Uso:
#   sudo ./verify.sh
#   sudo DEPLOY_USER=deploy ./verify.sh
#
# Imprime PASS/FAIL por chequeo y un resumen. Codigo de salida = numero de FAIL.

set -uo pipefail   # NO -e: queremos correr TODOS los chequeos y contar fallos.

DEPLOY_USER="${DEPLOY_USER:-deploy}"
SSH_PORT="${SSH_PORT:-22}"
TEST_BAN_IP="${TEST_BAN_IP:-203.0.113.7}"   # IP de documentacion (RFC 5737), inofensiva.

FAILS=0

pass() { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS + 1)); }
sect() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

# check "<descripcion>" <comando...>  -> PASS si el comando sale 0.
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

[[ "${EUID}" -eq 0 ]] || { echo "Ejecutalo como root (sudo)."; exit 255; }

# ── Fase 3: firewall de host ────────────────────────────────────────────────
sect "Firewall (ufw)"
check "ufw activo"                ufw status verbose
ufw status verbose 2>/dev/null | grep -q "Status: active" || fail "ufw Status no es 'active'"
# Regla v6 real: ufw status numbered marca las reglas v6 con '(v6)'.
if ufw status 2>/dev/null | grep -q "${SSH_PORT}/tcp.*(v6)"; then
  pass "regla SSH v6 presente (IPv6 no es punto ciego)"
else
  fail "no se ve regla SSH para IPv6 (revisa IPV6=yes en /etc/default/ufw)"
fi

# ── Fase 5: SSH hardening (config EFECTIVA) ─────────────────────────────────
sect "SSH hardening (sshd -T, config efectiva)"
SSHD_EFF="$(sshd -T 2>/dev/null)"
echo "$SSHD_EFF" | grep -qi '^permitrootlogin no'       && pass "PermitRootLogin no"        || fail "PermitRootLogin NO es 'no'"
echo "$SSHD_EFF" | grep -qi '^passwordauthentication no' && pass "PasswordAuthentication no" || fail "PasswordAuthentication NO es 'no'"
echo "$SSHD_EFF" | grep -qi "^allowusers .*${DEPLOY_USER}" && pass "AllowUsers incluye ${DEPLOY_USER}" || fail "AllowUsers NO acota a ${DEPLOY_USER}"

# root sin login real: la shell de root debe estar bloqueada/sin password util.
# passwd -S root => 'L' (locked) o 'NP'/'!' segun distro; aceptamos L.
if passwd -S root 2>/dev/null | awk '{print $2}' | grep -qE '^(L|LK)$'; then
  pass "cuenta root con password bloqueada (passwd -S = L)"
else
  fail "cuenta root NO figura con password bloqueada"
fi

# ── Fase 2: parcheo desatendido + auto-reboot ───────────────────────────────
sect "Auto-parcheo (unattended-upgrades)"
check "unattended-upgrades enabled" systemctl is-enabled unattended-upgrades
grep -rqi 'Unattended-Upgrade::Automatic-Reboot[[:space:]]\+"true"' /etc/apt/apt.conf.d/ \
  && pass "Automatic-Reboot = true (kernel parcheado SE reinicia)" \
  || fail "Automatic-Reboot NO esta en true (kernel quedaria vulnerable)"
# Lista de origenes de seguridad reconocida por el motor.
unattended-upgrade --dry-run -d >/dev/null 2>&1 \
  && pass "unattended-upgrade --dry-run resuelve origenes" \
  || fail "unattended-upgrade --dry-run fallo"

# ── Fase 2: timezone / NTP ──────────────────────────────────────────────────
sect "Reloj (timezone + NTP)"
timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q '^yes$' \
  && pass "NTPSynchronized = yes" || fail "reloj NO sincronizado (fail2ban/RPO en riesgo)"

# ── Fase 2: swap ────────────────────────────────────────────────────────────
sect "Swap (anti-OOM)"
swapon --show=NAME --noheadings 2>/dev/null | grep -q . \
  && pass "swap activo" || fail "no hay swap activo (OOM killer puede matar Postgres)"

# ── Fase 2: journald persistente ────────────────────────────────────────────
sect "journald"
journalctl --header 2>/dev/null | grep -qi 'persistent\|/var/log/journal' \
  || [[ -d /var/log/journal ]] \
  && pass "journal persistente" || fail "journal NO persistente (fail2ban pierde bans tras reboot)"

# ── Fase 7: daemon.json con rotacion ────────────────────────────────────────
sect "Docker daemon (rotacion de logs)"
if [[ -f /etc/docker/daemon.json ]] \
   && grep -q '"max-size"' /etc/docker/daemon.json \
   && grep -q '"max-file"' /etc/docker/daemon.json; then
  pass "daemon.json con max-size/max-file (logs rotan)"
else
  fail "daemon.json sin rotacion (disco se llena -> nodo caido)"
fi
# Efecto real: el daemon corre con el driver capeado.
docker info 2>/dev/null | grep -qi 'Logging Driver: json-file' \
  && pass "logging driver efectivo = json-file" || fail "logging driver efectivo no confirmado"

# ── Fase 7: Swarm activo ────────────────────────────────────────────────────
sect "Swarm"
docker info 2>/dev/null | grep -q "Swarm: active" \
  && pass "Swarm: active" || fail "Swarm NO esta activo"
docker node ls 2>/dev/null | grep -q "Leader" \
  && pass "nodo es Leader (manager)" || fail "no se ve nodo Leader"

# ── Fase 10: fail2ban activo + ban FUNCIONAL ────────────────────────────────
sect "fail2ban (activo + ban funcional)"
check "fail2ban activo" systemctl is-active fail2ban
fail2ban-client status sshd >/dev/null 2>&1 \
  && pass "jail sshd presente" || fail "jail sshd ausente"
# Prueba funcional: el jail puede estar 'running' sin banear nunca (backend systemd
# + banaction iptables que no matchea nft). Banear, confirmar en nft, desbanear.
if fail2ban-client set sshd banip "${TEST_BAN_IP}" >/dev/null 2>&1; then
  sleep 1
  if nft list ruleset 2>/dev/null | grep -q "${TEST_BAN_IP}" \
     || iptables -S 2>/dev/null | grep -q "${TEST_BAN_IP}"; then
    pass "ban funcional: ${TEST_BAN_IP} aparece en el ruleset"
  else
    fail "ban NO efectivo en el ruleset (fija banaction = nftables-multiport)"
  fi
  fail2ban-client set sshd unbanip "${TEST_BAN_IP}" >/dev/null 2>&1 || true
else
  fail "no se pudo inyectar el ban de prueba"
fi

# ── Fase 2/6: timers habilitados ────────────────────────────────────────────
sect "Timers"
check "apt-daily-upgrade.timer enabled" systemctl is-enabled apt-daily-upgrade.timer

# ── Resumen ─────────────────────────────────────────────────────────────────
sect "Resumen"
if [[ "${FAILS}" -eq 0 ]]; then
  printf '  \033[1;32mTODO PASS\033[0m — el nodo cumple las post-condiciones.\n'
else
  printf '  \033[1;31m%d FAIL\033[0m — el nodo NO esta listo. Revisa arriba.\n' "${FAILS}"
fi
# Reporte fechado PASS/FAIL conviene retenerlo off-host (ver doc 10):
#   sudo ./verify.sh | tee "verify-$(date +%F).log"
exit "${FAILS}"
