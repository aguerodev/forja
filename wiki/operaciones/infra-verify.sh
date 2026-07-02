#!/usr/bin/env bash
#
# infra-verify.sh — Gate de post-condiciones a NIVEL API (simetrico a verify.sh).
#
# verify.sh valida el INTERIOR del nodo (sshd, ufw, swarm...). Este valida el
# PLANO DE INFRA en Hetzner: que el estado vivo de la API coincida con la
# doctrina. Es la red contra el duplicate-create y la precondicion que habilita
# o bloquea cualquier rama de recreacion humana. Ver doc 12.
#
# Sale ≠0 (codigo = numero de FAIL) si:
#   - hay != 1 server con el label managed-by=agent (+ selector),
#   - el firewall no esta adjunto al server, o sus reglas != firewall-rules.json,
#   - 22/tcp no esta abierto en v4 Y v6, o hay algo MAS inbound abierto al mundo,
#   - el backup del proveedor no esta habilitado,
#   - enable-protection delete+rebuild no esta activa,
#   - el ultimo snapshot restic off-site no es fresco.
#
# Solo LECTURA: corre con el token READ y con `restic snapshots`. No muta nada.
#
# Uso:
#   HCLOUD_TOKEN=<read> \
#   HCLOUD_SELECTOR=managed-by=agent,project=<app>,env=<env> \
#   FW=<fw> RULES_FILE=operaciones/firewall-rules.json \
#   RESTIC_REPOSITORY=... RESTIC_PASSWORD_FILE=... \
#   ./infra-verify.sh

set -uo pipefail   # NO -e: corremos TODOS los chequeos y contamos fallos.

# ── Configuracion ───────────────────────────────────────────────────────────
: "${HCLOUD_TOKEN:?Falta HCLOUD_TOKEN (token READ) en el entorno}"
SELECTOR="${HCLOUD_SELECTOR:-managed-by=agent}"
FW="${FW:?Falta FW=<firewall> a verificar}"
RULES_FILE="${RULES_FILE:-$(dirname "$0")/firewall-rules.json}"
MAX_SNAPSHOT_AGE_H="${MAX_SNAPSHOT_AGE_H:-26}"   # ventana de frescura del backup diario
export HCLOUD_TOKEN

FAILS=0
pass() { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS + 1)); }
sect() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

command -v jq      >/dev/null 2>&1 || { echo "Falta jq (requerido)."; exit 255; }
command -v hcloud  >/dev/null 2>&1 || { echo "Falta hcloud CLI."; exit 255; }
[[ -f "${RULES_FILE}" ]] || { echo "No existe el ruleset: ${RULES_FILE}"; exit 255; }
[[ "${SELECTOR}" == *managed-by=agent* ]] || { echo "El selector DEBE incluir managed-by=agent"; exit 255; }

# ── 1. Exactamente 1 server con el label ────────────────────────────────────
sect "Identidad (1 server por label)"
SRV_JSON="$(hcloud server list -l "${SELECTOR}" -o json 2>/dev/null || echo '[]')"
N="$(printf '%s' "${SRV_JSON}" | jq 'length')"
if [[ "${N}" == "1" ]]; then
  pass "exactamente 1 server con ${SELECTOR}"
else
  fail "se esperaba 1 server con ${SELECTOR}, hay ${N} (duplicate-create o borrado)"
fi
SRV="$(printf '%s' "${SRV_JSON}" | jq '.[0]')"
SRV_ID="$(printf '%s' "${SRV}" | jq -r '.id // empty')"

# ── 2. Backup del proveedor habilitado ──────────────────────────────────────
sect "Backup del proveedor"
if [[ "$(printf '%s' "${SRV}" | jq -r '.backup_window // "null"')" != "null" ]]; then
  pass "backup habilitado (backup_window presente)"
else
  fail "backup NO habilitado (sin backup_window)"
fi

# ── 3. enable-protection delete + rebuild activa ────────────────────────────
sect "Proteccion a nivel API (delete + rebuild)"
PROT_DEL="$(printf '%s' "${SRV}" | jq -r '.protection.delete // false')"
PROT_REB="$(printf '%s' "${SRV}" | jq -r '.protection.rebuild // false')"
[[ "${PROT_DEL}" == "true" ]] && pass "protection.delete = true"  || fail "protection.delete NO activa (el R&W podria borrar)"
[[ "${PROT_REB}" == "true" ]] && pass "protection.rebuild = true" || fail "protection.rebuild NO activa (el R&W podria reconstruir)"

# ── 4. Firewall adjunto al server ───────────────────────────────────────────
sect "Firewall adjunto"
ATTACHED="$(printf '%s' "${SRV}" | jq --arg fw "${FW}" '
  [ (.public_net.firewalls // [])[] | .firewall // . ] | length > 0' 2>/dev/null)"
# El listado del server trae IDs; confirmamos contra el firewall por su nombre.
FW_JSON="$(hcloud firewall describe "${FW}" -o json 2>/dev/null || echo '{}')"
FW_ID="$(printf '%s' "${FW_JSON}" | jq -r '.id // empty')"
APPLIED_TO_SRV="$(printf '%s' "${FW_JSON}" | jq --arg id "${SRV_ID}" '
  [ (.applied_to // [])[] | select((.server.id // .applied_to_resources[]?.server.id // "") | tostring == $id) ] | length > 0' 2>/dev/null)"
if [[ "${APPLIED_TO_SRV}" == "true" ]]; then
  pass "firewall '${FW}' adjunto al server ${SRV_ID}"
else
  fail "firewall '${FW}' NO adjunto al server ${SRV_ID}"
fi

# ── 5. Reglas vivas == firewall-rules.json ──────────────────────────────────
# Normalizamos ambos lados (orden y campos vacios) y comparamos por hash.
sect "Reglas vivas == archivo versionado"
NORM='[ .[] | { direction, protocol, port: (.port // null),
                source_ips: ((.source_ips // []) | sort),
                destination_ips: ((.destination_ips // []) | sort) } ]
      | sort_by(.direction, .protocol, (.port // ""), (.source_ips|tostring), (.destination_ips|tostring))'
LIVE_NORM="$(printf '%s' "${FW_JSON}" | jq -S "(.rules // []) | ${NORM}" 2>/dev/null)"
FILE_NORM="$(jq -S "${NORM}" "${RULES_FILE}" 2>/dev/null)"
if [[ -n "${LIVE_NORM}" && "${LIVE_NORM}" == "${FILE_NORM}" ]]; then
  pass "reglas vivas identicas a ${RULES_FILE}"
else
  fail "DRIFT: reglas vivas != ${RULES_FILE} (corre replace-rules tras revisar el diff)"
fi

# ── 6. Inbound: 22 abierto v4+v6 y NADA mas al mundo ────────────────────────
sect "Inbound del borde (solo 22/tcp v4+v6)"
SSH_V4="$(printf '%s' "${FW_JSON}" | jq '[ (.rules // [])[]
  | select(.direction=="in" and (.protocol|ascii_downcase)=="tcp" and (.port|tostring)=="22")
  | (.source_ips // []) | index("0.0.0.0/0") ] | any')"
SSH_V6="$(printf '%s' "${FW_JSON}" | jq '[ (.rules // [])[]
  | select(.direction=="in" and (.protocol|ascii_downcase)=="tcp" and (.port|tostring)=="22")
  | (.source_ips // []) | index("::/0") ] | any')"
[[ "${SSH_V4}" == "true" ]] && pass "22/tcp abierto en IPv4" || fail "22/tcp NO abierto en IPv4"
[[ "${SSH_V6}" == "true" ]] && pass "22/tcp abierto en IPv6" || fail "22/tcp NO abierto en IPv6 (punto ciego)"

# Cualquier inbound al mundo (0.0.0.0/0 o ::/0) en un puerto != 22 = FAIL.
EXTRA_OPEN="$(printf '%s' "${FW_JSON}" | jq -r '[ (.rules // [])[]
  | select(.direction=="in")
  | select((.source_ips // []) | any(. == "0.0.0.0/0" or . == "::/0"))
  | select((.port|tostring) != "22")
  | "\(.protocol):\(.port // "any")" ] | unique | .[]')"
if [[ -z "${EXTRA_OPEN}" ]]; then
  pass "no hay inbound al mundo fuera de 22/tcp"
else
  while IFS= read -r e; do fail "inbound al mundo prohibido abierto -> ${e}"; done <<< "${EXTRA_OPEN}"
fi

# ── 7. Snapshot restic FRESCO (RPO de negocio, off-site) ────────────────────
sect "Backup restic off-site (frescura)"
if command -v restic >/dev/null 2>&1 && [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
  LATEST="$(restic snapshots --json --latest 1 2>/dev/null \
            | jq -r 'sort_by(.time) | last | .time // empty')"
  if [[ -n "${LATEST}" ]]; then
    LATEST_EPOCH="$(date -j -f '%Y-%m-%dT%H:%M:%S' "${LATEST%%.*}" +%s 2>/dev/null \
                    || date -d "${LATEST}" +%s 2>/dev/null || echo 0)"
    AGE_H=$(( ( $(date +%s) - LATEST_EPOCH ) / 3600 ))
    if [[ "${LATEST_EPOCH}" -gt 0 && "${AGE_H}" -le "${MAX_SNAPSHOT_AGE_H}" ]]; then
      pass "ultimo snapshot restic hace ${AGE_H}h (<= ${MAX_SNAPSHOT_AGE_H}h)"
    else
      fail "snapshot restic NO fresco: ${AGE_H}h (> ${MAX_SNAPSHOT_AGE_H}h)"
    fi
  else
    fail "no se pudo leer ningun snapshot restic (repo vacio o inaccesible)"
  fi
else
  fail "restic no disponible o RESTIC_REPOSITORY sin definir (no se valida RPO off-site)"
fi

# ── Resumen ─────────────────────────────────────────────────────────────────
sect "Resumen"
if [[ "${FAILS}" -eq 0 ]]; then
  printf '  \033[1;32mTODO PASS\033[0m — el plano de infra cumple la doctrina.\n'
else
  printf '  \033[1;31m%d FAIL\033[0m — la infra NO esta conforme. Revisa arriba.\n' "${FAILS}"
fi
# Conviene retener el reporte off-host (doc 10):
#   ./infra-verify.sh | tee "infra-verify-$(date +%F).log"
exit "${FAILS}"
