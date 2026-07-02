#!/usr/bin/env bash
#
# validate-firewall-rules.sh — Validador BLOQUEANTE del ruleset declarativo.
#
# Es el "linter de seguridad" que corre ANTES de cualquier `hcloud firewall
# replace-rules`. Sale ≠0 (bloquea el apply) si el archivo:
#   - tiene 0.0.0.0/0 o ::/0 en un puerto inbound que NO esta en la allowlist,
#   - abre un puerto al mundo en una sola familia (falta el par v4/v6 -> IPv6
#     seria un punto ciego),
#   - no contiene la regla SSH (22/tcp) en v4 Y v6.
#
# Filosofia (igual que verify.sh): la verdad vive en el script, no en la prosa.
# Abrir el borde es tan peligroso como borrar; por eso el control es un exit
# code, no un parrafo. Ver operaciones/12_how-to-gestionar-infra-via-api.md.
#
# Uso:
#   ./validate-firewall-rules.sh [ruta/al/firewall-rules.json]
#   ALLOW_WORLD_PORTS="22" ./validate-firewall-rules.sh
#
# La allowlist es deliberadamente minima: solo SSH. Ampliarla exige editar
# este archivo (queda en el diff de git = auditoria).

set -euo pipefail

RULES_FILE="${1:-$(dirname "$0")/firewall-rules.json}"

# Puertos que SI pueden quedar expuestos a 0.0.0.0/0 + ::/0 (separados por coma).
# Default: solo 22 (SSH). El borde real entra por Cloudflare Tunnel saliente,
# no por puertos abiertos (ver doc 05).
ALLOW_WORLD_PORTS="${ALLOW_WORLD_PORTS:-22}"

ERRORS=0
err()  { printf '  \033[1;31mBLOCK\033[0m %s\n' "$*"; ERRORS=$((ERRORS + 1)); }
ok()   { printf '  \033[1;32mOK\033[0m    %s\n'  "$*"; }
sect() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

command -v jq >/dev/null 2>&1 || { echo "Falta jq (requerido)."; exit 255; }
[[ -f "${RULES_FILE}" ]] || { echo "No existe el ruleset: ${RULES_FILE}"; exit 255; }

# ── 0. JSON valido + es un array ────────────────────────────────────────────
sect "Estructura"
if ! jq -e 'type == "array"' "${RULES_FILE}" >/dev/null 2>&1; then
  echo "  \033[1;31mBLOCK\033[0m JSON invalido o no es un array de reglas."
  exit 1
fi
ok "JSON valido y es un array de reglas"

# La allowlist como array JSON para cruzarla en jq.
ALLOW_JSON="$(printf '%s' "${ALLOW_WORLD_PORTS}" \
  | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')"

WORLD='["0.0.0.0/0","::/0"]'

# ── 1. Ningun puerto al mundo fuera de la allowlist ─────────────────────────
# Por cada regla inbound, si algun source_ip es una ruta-cero (v4 o v6) y el
# puerto NO esta en la allowlist -> bloquear. Cubre tambien reglas sin puerto
# (icmp/gre/esp), que jamas deben quedar abiertas al mundo.
sect "Inbound abierto al mundo (solo allowlist)"
OFFENDERS="$(jq -r --argjson allow "${ALLOW_JSON}" --argjson world "${WORLD}" '
  [ .[]
    | select(.direction == "in")
    | . as $r
    | ((.source_ips // []) | any(. as $ip | $world | index($ip)))   as $hasWorld
    | (.port // "any")                                              as $port
    | select($hasWorld and (($allow | index($port)) == null))
    | "\(.protocol // "?"):\($port)"
  ] | unique | .[]
' "${RULES_FILE}")"

if [[ -n "${OFFENDERS}" ]]; then
  while IFS= read -r o; do
    err "puerto abierto al mundo fuera de la allowlist -> ${o}"
  done <<< "${OFFENDERS}"
else
  ok "ningun inbound 0.0.0.0/0 o ::/0 fuera de {${ALLOW_WORLD_PORTS}}"
fi

# ── 2. La regla SSH (22/tcp) existe en v4 Y v6 ──────────────────────────────
sect "Regla SSH presente (22/tcp)"
SSH_V4="$(jq '[ .[] | select(.direction=="in" and (.protocol|ascii_downcase)=="tcp" and (.port|tostring)=="22")
                | (.source_ips // []) | index("0.0.0.0/0") ] | any' "${RULES_FILE}")"
SSH_V6="$(jq '[ .[] | select(.direction=="in" and (.protocol|ascii_downcase)=="tcp" and (.port|tostring)=="22")
                | (.source_ips // []) | index("::/0") ] | any' "${RULES_FILE}")"

[[ "${SSH_V4}" == "true" ]] && ok "SSH 22/tcp alcanzable en IPv4 (0.0.0.0/0)" \
  || err "falta la regla SSH 22/tcp para IPv4 (0.0.0.0/0)"
[[ "${SSH_V6}" == "true" ]] && ok "SSH 22/tcp alcanzable en IPv6 (::/0)" \
  || err "falta la regla SSH 22/tcp para IPv6 (::/0) -> IPv6 seria punto ciego"

# ── 3. Simetria v4/v6 en TODO puerto allowlisted que se exponga ─────────────
# Si un puerto de la allowlist aparece abierto al mundo, debe estarlo en AMBAS
# familias. Abrir solo v4 deja la puerta v6 sin candado (o al reves).
sect "Simetria v4/v6 en puertos expuestos"
ASYM="$(jq -r --argjson allow "${ALLOW_JSON}" '
  [ .[] | select(.direction=="in") | (.port|tostring) as $p
          | select($allow | index($p))
          | { p: $p, srcs: (.source_ips // []) } ]
  | group_by(.p)
  | map({ port: .[0].p,
          v4: (map(.srcs) | add | index("0.0.0.0/0") != null),
          v6: (map(.srcs) | add | index("::/0")     != null) })
  | map(select(.v4 != .v6) | "\(.port) (v4=\(.v4) v6=\(.v6))")
  | .[]
' "${RULES_FILE}")"

if [[ -n "${ASYM}" ]]; then
  while IFS= read -r a; do
    err "puerto expuesto en una sola familia (falta par v4/v6) -> ${a}"
  done <<< "${ASYM}"
else
  ok "todo puerto expuesto tiene su par v4 + v6"
fi

# ── Resumen ─────────────────────────────────────────────────────────────────
sect "Resumen"
if [[ "${ERRORS}" -eq 0 ]]; then
  printf '  \033[1;32mRULESET OK\033[0m — apto para replace-rules.\n'
  exit 0
fi
printf '  \033[1;31m%d BLOQUEO(S)\033[0m — NO aplicar este ruleset.\n' "${ERRORS}"
exit "${ERRORS}"
