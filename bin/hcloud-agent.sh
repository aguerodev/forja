#!/usr/bin/env bash
#
# hcloud-agent.sh — UNICO choke-point entre el agente de IA y la API de Hetzner.
#
# El agente NUNCA llama `hcloud` crudo. Llama a este wrapper, que es la frontera
# ejecutable entre "lo deseable" y "lo obligatorio" (ver doc 12). Responsabilidades:
#   (a) ALLOWLIST de verbos logicos: lo que no esta listado, no existe.
#   (b) DENIEGA lo destructivo/expansivo sin --human-approved explicito.
#   (c) FUERZA selector por label en cada llamada (identidad = label, no nombre/IP).
#   (d) Emite SIEMPRE -o json (nunca scrapear la tabla humana).
#   (e) 429 -> backoff exponencial; 409/locked -> POLLEA la accion async
#       (nunca reintento ciego: Hetzner devuelve acciones y limita ~3600 req/h).
#   (f) AUDITORIA append-only FUERA del host (journald + webhook) con run-id.
#
# El token va SIEMPRE por ${HCLOUD_TOKEN} (env). JAMAS como argumento de CLI:
# apareceria en `ps`/history. hcloud lo lee solo del entorno.
#
# Modelo de tokens (doc 07): el loop autonomo usa el token READ. Los verbos
# aditivos y los --human-approved exigen inyectar el token READ&WRITE break-glass
# just-in-time (vaulted, NUNCA persistido en el nodo). Este wrapper no decide el
# token: usa el ${HCLOUD_TOKEN} que reciba; quien lo invoca elige cual inyecta.
#
# Uso:
#   HCLOUD_TOKEN=... ./hcloud-agent.sh <verbo> [--selector k=v,...] [args]
#   ./hcloud-agent.sh list   --selector managed-by=agent,app=<app>,env=<env>
#   ./hcloud-agent.sh ip     --selector managed-by=agent,app=<app>
#   ./hcloud-agent.sh create-if-not-exists --selector ... -- <args-create-hcloud>
#   ./hcloud-agent.sh firewall-replace --human-approved --fw <fw> --rules-file <f>
#
# Salida: JSON en stdout para los verbos de lectura; logs/auditoria a stderr.

set -euo pipefail

# ── Configuracion (todo por env, sin defaults peligrosos) ───────────────────
: "${HCLOUD_TOKEN:?Falta HCLOUD_TOKEN en el entorno (nunca como argumento)}"
SELECTOR_BASE="${HCLOUD_SELECTOR:-managed-by=agent}"   # label minimo no negociable
AUDIT_WEBHOOK="${AUDIT_WEBHOOK:-}"                      # ntfy/Slack/Telegram (doc 10)
MAX_RETRIES="${MAX_RETRIES:-6}"                         # tope de reintentos 429/409
POLL_INTERVAL="${POLL_INTERVAL:-3}"                     # seg entre polls de accion
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}}"

export HCLOUD_TOKEN   # hcloud lo toma del entorno; nunca lo pasamos como flag.

# ── Allowlist de verbos ─────────────────────────────────────────────────────
# READ      : token READ alcanza, blast radius cero.
# ADDITIVE  : no destruye, da rollback; exige token R&W just-in-time.
# GATED     : destructivo o expansivo; exige --human-approved (clase human-confirmed).
#             delete/rebuild ademas deberian estar bloqueados por enable-protection
#             a nivel API: este flag NO sustituye quitar la proteccion en consola.
READ_VERBS="list describe ip metrics firewall-describe"
ADDITIVE_VERBS="create-if-not-exists enable-backup create-image-snapshot reboot"
GATED_VERBS="delete rebuild firewall-replace change-type"

die() { printf '\033[1;31m[hcloud-agent] %s\033[0m\n' "$*" >&2; exit 1; }

in_list() { local x="$1"; shift; local v; for v in $*; do [[ "$v" == "$x" ]] && return 0; done; return 1; }

# ── Auditoria off-host (append-only) ────────────────────────────────────────
# Cada mutacion deja rastro atribuible FUERA del nodo. Sin esto los cambios del
# agente no son reversibles con evidencia (Hetzner no da audit per-recurso rico).
audit() {
  local event="$1" detail="${2:-}"
  local line
  line="$(printf '{"ts":"%s","actor":"agent","run_id":"%s","event":"%s","selector":"%s","detail":"%s"}' \
            "$(date -u +%FT%TZ)" "${RUN_ID}" "${event}" "${SELECTOR}" "${detail//\"/\'}")"
  # journald: persistente y fuera del proceso del agente.
  command -v logger >/dev/null 2>&1 && logger -t hcloud-agent -- "${line}" || true
  # Webhook: copia inmutable off-host (mismo canal que el monitoreo, doc 10).
  if [[ -n "${AUDIT_WEBHOOK}" ]]; then
    curl -fsS --max-time 5 -H 'Content-Type: application/json' \
      -d "${line}" "${AUDIT_WEBHOOK}" >/dev/null 2>&1 || \
      printf '[hcloud-agent] WARN: webhook de auditoria fallo\n' >&2
  fi
  printf '%s\n' "${line}" >&2
}

# ── Ejecutor con backoff(429) y poll(409) ───────────────────────────────────
# Corre `hcloud "$@"` capturando stderr. Discrimina por el mensaje de la API:
#   - rate limit / 429  -> backoff exponencial y reintenta.
#   - locked / conflict / 409 / "action ... is running" -> la accion previa sigue
#     async: esperamos (poll) y reintentamos, NUNCA a ciegas en bucle cerrado.
hc() {
  local attempt=0 delay=2 out err rc
  while :; do
    attempt=$((attempt + 1))
    err="$(mktemp)"
    set +e
    out="$(hcloud "$@" 2>"${err}")"; rc=$?
    set -e
    if [[ ${rc} -eq 0 ]]; then rm -f "${err}"; printf '%s' "${out}"; return 0; fi

    local msg; msg="$(tr '[:upper:]' '[:lower:]' < "${err}")"; rm -f "${err}"
    if [[ ${attempt} -ge ${MAX_RETRIES} ]]; then
      die "hcloud $1 fallo tras ${attempt} intentos: ${msg}"
    fi
    if printf '%s' "${msg}" | grep -qE 'rate.?limit|429|too many requests'; then
      printf '[hcloud-agent] 429 rate-limit; backoff %ss (intento %s)\n' "${delay}" "${attempt}" >&2
      sleep "${delay}"; delay=$((delay * 2))
    elif printf '%s' "${msg}" | grep -qE 'locked|conflict|409|action.*(running|in progress)'; then
      printf '[hcloud-agent] 409 recurso ocupado; poll %ss (intento %s)\n' "${POLL_INTERVAL}" "${attempt}" >&2
      sleep "${POLL_INTERVAL}"
    else
      die "hcloud $1 error no recuperable: ${msg}"
    fi
  done
}

# Resuelve EXACTAMENTE 1 server por el selector. >1 = hard stop (jamas elige).
resolve_one_id() {
  local n
  SRV_JSON="$(hc server list -l "${SELECTOR}" -o json)"
  n="$(printf '%s' "${SRV_JSON}" | jq 'length')"
  case "${n}" in
    0) die "selector ${SELECTOR} no matchea ningun server (nada que tocar)";;
    1) printf '%s' "${SRV_JSON}" | jq -r '.[0].id';;
    *) die "AMBIGUO: ${n} servers matchean ${SELECTOR}. El agente jamas elige uno.";;
  esac
}

# ── Parseo de argumentos ────────────────────────────────────────────────────
VERB="${1:-}"; shift || true
[[ -n "${VERB}" ]] || die "Falta el verbo. Permitidos: ${READ_VERBS} ${ADDITIVE_VERBS} ${GATED_VERBS}"

HUMAN_APPROVED=0
SELECTOR_EXTRA=""
FW=""
RULES_FILE=""
PASSTHRU=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --human-approved) HUMAN_APPROVED=1; shift;;
    --selector)       SELECTOR_EXTRA="$2"; shift 2;;
    --fw)             FW="$2"; shift 2;;
    --rules-file)     RULES_FILE="$2"; shift 2;;
    --)               shift; PASSTHRU=("$@"); break;;
    *)                PASSTHRU+=("$1"); shift;;
  esac
done

# Selector OBLIGATORIO y siempre incluye el label minimo managed-by=agent.
if [[ -n "${SELECTOR_EXTRA}" ]]; then
  SELECTOR="${SELECTOR_BASE},${SELECTOR_EXTRA}"
else
  SELECTOR="${SELECTOR_BASE}"
fi
[[ "${SELECTOR}" == *managed-by=agent* ]] || die "El selector DEBE incluir managed-by=agent"

# ── Despacho por clase ──────────────────────────────────────────────────────
if in_list "${VERB}" "${GATED_VERBS}"; then
  [[ "${HUMAN_APPROVED}" -eq 1 ]] || \
    die "VERBO GATED '${VERB}' DENEGADO sin --human-approved (clase human-confirmed)."
  audit "gated-approved" "verbo=${VERB}"
fi

case "${VERB}" in
  # ── READ (token READ, blast radius cero) ──────────────────────────────────
  list)
    hc server list -l "${SELECTOR}" -o json
    ;;
  describe)
    ID="$(resolve_one_id)"
    hc server describe "${ID}" -o json
    ;;
  ip)
    # IP DERIVADA de la API, nunca cacheada. Contempla IPv6-only (ipv4 = null).
    hc server list -l "${SELECTOR}" -o json | jq -r '.[0].public_net.ipv4.ip // empty'
    ;;
  metrics)
    ID="$(resolve_one_id)"
    hc server metrics "${ID}" ${PASSTHRU[@]+"${PASSTHRU[@]}"} -o json
    ;;
  firewall-describe)
    [[ -n "${FW}" ]] || die "firewall-describe requiere --fw <fw>"
    hc firewall describe "${FW}" -o json
    ;;

  # ── ADDITIVE (no destruye; exige token R&W just-in-time) ──────────────────
  create-if-not-exists)
    # Confirmar-o-crear idempotente: crear SOLO si el selector vuelve vacio.
    N="$(hc server list -l "${SELECTOR}" -o json | jq 'length')"
    case "${N}" in
      0) audit "create" "selector=${SELECTOR}"
         # Cada k=v del selector nace como label del nuevo server (identidad por label).
         LABEL_ARGS=()
         IFS=',' read -ra _kvs <<< "${SELECTOR}"
         for _kv in "${_kvs[@]}"; do LABEL_ARGS+=(--label "${_kv}"); done
         hc server create ${LABEL_ARGS[@]+"${LABEL_ARGS[@]}"} ${PASSTHRU[@]+"${PASSTHRU[@]}"} -o json
         ;;
      1) printf '[hcloud-agent] ya existe 1 server con %s; no se recrea.\n' "${SELECTOR}" >&2
         hc server list -l "${SELECTOR}" -o json
         ;;
      *) die "AMBIGUO: ${N} servers con ${SELECTOR}. Stop antes de crear.";;
    esac
    ;;
  enable-backup)
    ID="$(resolve_one_id)"; audit "enable-backup" "id=${ID}"
    hc server enable-backup "${ID}"
    ;;
  create-image-snapshot)
    # Snapshot pre-cambio: additivo, da rollback. Etiquetado para identidad.
    ID="$(resolve_one_id)"; audit "snapshot" "id=${ID}"
    hc server create-image --type snapshot \
      --label managed-by=agent --label reason=pre-change \
      --description "pre-change-${RUN_ID}" "${ID}" -o json
    ;;
  reboot)
    # Reinicio graceful (NO `reset`, que es corte duro).
    ID="$(resolve_one_id)"; audit "reboot" "id=${ID}"
    hc server reboot "${ID}"
    ;;

  # ── GATED (human-confirmed; ya validado --human-approved arriba) ──────────
  firewall-replace)
    [[ -n "${FW}" && -n "${RULES_FILE}" ]] || die "firewall-replace requiere --fw y --rules-file"
    # Pre-condicion dura: el validador debe pasar ANTES de tocar el borde.
    "$(dirname "$0")/validate-firewall-rules.sh" "${RULES_FILE}" \
      || die "validate-firewall-rules.sh bloqueo el ruleset; no se aplica."
    audit "firewall-replace" "fw=${FW} file=${RULES_FILE}"
    hc firewall replace-rules "${FW}" --rules-file "${RULES_FILE}" -o json
    ;;
  change-type)
    ID="$(resolve_one_id)"; audit "change-type" "id=${ID} args=${PASSTHRU[*]}"
    hc server change-type "${ID}" ${PASSTHRU[@]+"${PASSTHRU[@]}"}
    ;;
  delete|rebuild)
    # Llega aca solo con --human-approved, PERO enable-protection deberia
    # rechazarlo igual a nivel API. No removemos la proteccion desde el wrapper.
    ID="$(resolve_one_id)"; audit "${VERB}-attempt" "id=${ID}"
    die "PROHIBIDO al agente: '${VERB}' requiere quitar enable-protection en consola (humano)."
    ;;

  *)
    die "Verbo no permitido: '${VERB}'. Allowlist: ${READ_VERBS} ${ADDITIVE_VERBS} ${GATED_VERBS}"
    ;;
esac
