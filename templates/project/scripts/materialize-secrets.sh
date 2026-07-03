#!/usr/bin/env bash
# scripts/materialize-secrets.sh — materializa los secretos del equipo DESDE el
# gestor (Bitwarden CLI) a sus lugares locales (doctrina: wiki ops/07, how-to
# ops/13). NO contiene ningún valor: los lee del gestor en runtime.
#
#   engram = el saber · gestor = el secreto · git = el codigo.
#
# Declarativo: lee `secrets/secrets-map.json` (versionado, SIN valores) y
# materializa cada entrada segun su tipo `as`:
#   - "env"     : upsert idempotente de KEY=value (o `export KEY='value'`) en el
#                 archivo `dest`, keyed por `field`. Para globales (~/.zshenv...).
#   - "envfile" : vuelca TODOS los campos del item como lineas key=value en
#                 `dest` (materializa p. ej. secrets/prod.env entero).
#   - "file"    : escribe el valor de `field` en `dest` con permisos `mode`.
#
# Secciones del mapa:
#   - global[] : SIEMPRE se materializa. API keys compartidas cross-proyecto,
#                items SIN carpeta en el vault.
#   - prod[]   : SOLO con --prod (operador). Items ESPECIFICOS del proyecto,
#                resueltos dentro de la carpeta del vault cuyo nombre == `app`
#                de .forja.json (desambigua items homonimos entre proyectos).
#
# Frontera humano/agente: la master password la maneja SOLO el humano. Este
# script opera con un BW_SESSION ya desbloqueado y HEREDADO DEL ENTORNO — nunca
# lo recibe por argumento (un `--session <val>` quedaria expuesto en `ps` y en
# el historial del shell). Al terminar, cerra el acceso con `bw lock`.
#
# Seguridad de escritura: los valores nunca pasan por la linea de comandos (van
# por stdin a node). Los destinos `env` se ESCRIBEN CON COMILLAS SIMPLES y
# escape, porque la shell los SOURCEA (~/.zshenv se carga en todo shell) — un
# valor con $(...), backticks o comillas no puede inyectar comandos. Toda
# escritura es atomica (tmp con mode 0600 + rename), sin ventana de permisos.
#
# Requisitos: bw CLI + node + BW_SESSION exportado
#   (export BW_SESSION="$(bw unlock --raw)").
# Uso: ./scripts/materialize-secrets.sh [--prod]
set -euo pipefail
umask 077

# ── Argumentos y precondiciones ──────────────────────────────────────────────
WITH_PROD=0
[ "${1:-}" = "--prod" ] && WITH_PROD=1

[ -n "${BW_SESSION:-}" ] || {
  echo "[FAIL] export BW_SESSION=\"\$(bw unlock --raw)\" antes de correr" >&2
  exit 1
}
export BW_SESSION  # bw lo HEREDA del entorno; nunca se pasa por --session

command -v bw   >/dev/null 2>&1 || { echo "[FAIL] bw CLI ausente" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "[FAIL] node ausente"   >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$(node -p 'require("./.forja.json").app' 2>/dev/null || echo app)"
MAP="$REPO/secrets/secrets-map.json"

[ -f "$MAP" ] || { echo "[FAIL] falta el mapa: $MAP" >&2; exit 1; }
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$MAP" \
  2>/dev/null || { echo "[FAIL] $MAP no es JSON valido" >&2; exit 1; }

# ── Helpers ──────────────────────────────────────────────────────────────────

# Expande ${APP} y un ~ inicial en una ruta destino. Rechaza rutas con `..`
# (un dest del mapa con path traversal podria pisar dotfiles fuera de lo previsto).
expand_path() {
  local p="$1"
  p="${p//\$\{APP\}/$APP}"
  p="${p/#\~/$HOME}"
  case "$p" in
    *..*) echo "[FAIL] dest con '..' no permitido: $p" >&2; exit 1 ;;
  esac
  printf '%s' "$p"
}

# Emite las entradas de una seccion del mapa, un registro por linea, con campos
# separados por US (\x1f, unit separator):
#   as \x1f item \x1f field \x1f dest \x1f export(0|1) \x1f mode
# NO usamos TAB: el TAB es IFS-whitespace y bash colapsa delimitadores
# consecutivos, asi que un `field` vacio (p. ej. en las entradas `as=envfile`)
# desplazaria las columnas. \x1f no es whitespace: preserva los campos vacios.
map_section() {
  node -e '
    const fs = require("fs");
    const US = String.fromCharCode(31);
    const map = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const section = map[process.argv[2]] || [];
    for (const e of section) {
      const row = [
        e.as || "env",
        e.item || "",
        e.field || "",
        e.dest || "",
        e.export ? "1" : "0",
        e.mode || "600",
      ];
      process.stdout.write(row.join(US) + "\n");
    }
  ' "$MAP" "$1"
}

# Devuelve el JSON de un item del vault por stdout.
#   $1 = nombre del item · $2 = folderid ("" = global, sin carpeta)
# bw y node se corren SEPARADO (no en un pipe bajo `set -o pipefail`): un fallo
# transitorio de bw dentro de `var="$(cmd | node)"` abortaria el script entero
# en silencio. Aca un bw fallido devuelve vacio ("sin acceso"), no mata la corrida.
fetch_item() {
  local out
  if [ -n "$2" ]; then
    out="$(bw list items --folderid "$2" --search "$1" 2>/dev/null)" || return 0
    [ -n "$out" ] || return 0
    printf '%s' "$out" | node -e '
      const fs = require("fs");
      const items = JSON.parse(fs.readFileSync(0, "utf8") || "[]");
      const it = items.find((x) => x.name === process.argv[1]);
      if (it) process.stdout.write(JSON.stringify(it));
    ' "$1"
  else
    bw get item "$1" 2>/dev/null || true
  fi
}

# Resuelve el folderid del vault cuyo nombre == $1. Vacio si no existe.
folder_id() {
  local out
  out="$(bw list folders 2>/dev/null)" || return 0
  [ -n "$out" ] || return 0
  printf '%s' "$out" | node -e '
    const fs = require("fs");
    const folders = JSON.parse(fs.readFileSync(0, "utf8") || "[]");
    const f = folders.find((x) => x.name === process.argv[1]);
    if (f && f.id) process.stdout.write(String(f.id));
  ' "$1"
}

# as=env: upsert idempotente de field=value en dest. Item JSON por stdin.
#   argv: field dest export(0|1). Exit 3 si el campo esta vacio/ausente.
# El valor va ENTRE COMILLAS SIMPLES con escape (el dest lo sourcea la shell);
# elimina TODAS las lineas previas de la misma KEY (no solo la primera) y
# escribe atomico (tmp 0600 + rename) para no corromper el dotfile del usuario.
apply_env() {
  # shellcheck disable=SC2016  # el cuerpo es JS (node -e), los $ no son del shell
  node -e '
    const fs = require("fs");
    const path = require("path");
    const field = process.argv[1], dest = process.argv[2], exp = process.argv[3];
    const it = JSON.parse(fs.readFileSync(0, "utf8"));
    const f = (it.fields || []).find((x) => x.name === field);
    if (!f || f.value == null || String(f.value) === "") process.exit(3);
    const val = String(f.value);
    const SQ = String.fromCharCode(39);                 // comilla simple
    const quoted = SQ + val.split(SQ).join(SQ + "\\" + SQ + SQ) + SQ;  // val -> '\''-escaped
    const line = exp === "1" ? "export " + field + "=" + quoted : field + "=" + quoted;
    let cur = "";
    try { cur = fs.readFileSync(dest, "utf8"); } catch (e) { /* archivo nuevo */ }
    const esc = field.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const re = new RegExp("^(?:export\\s+)?" + esc + "=");
    let lines = cur.length ? cur.split("\n") : [];
    if (lines.length && lines[lines.length - 1] === "") lines.pop();   // quita el "" del \n final
    lines = lines.filter((l) => !re.test(l));           // saca TODAS las lineas de esta KEY
    lines.push(line);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const tmp = dest + ".tmp." + process.pid;
    fs.writeFileSync(tmp, lines.join("\n") + "\n", { mode: 0o600 });
    fs.renameSync(tmp, dest);
  ' "$1" "$2" "$3"
}

# as=envfile: vuelca TODOS los campos del item como key=value en dest.
#   argv: dest. Escritura atomica (.tmp + rename). Exit 3 si el item no tiene campos.
apply_envfile() {
  node -e '
    const fs = require("fs");
    const path = require("path");
    const dest = process.argv[1];
    const it = JSON.parse(fs.readFileSync(0, "utf8"));
    const fields = it.fields || [];
    if (fields.length === 0) process.exit(3);
    const body =
      fields.map((f) => f.name + "=" + (f.value == null ? "" : String(f.value))).join("\n") + "\n";
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const tmp = dest + ".tmp." + process.pid;
    fs.writeFileSync(tmp, body, { mode: 0o600 });
    fs.renameSync(tmp, dest);
  ' "$1"
}

# as=file: escribe el valor de field en dest con permisos mode.
#   argv: field dest mode. Escritura atomica. Exit 3 si el campo esta vacio.
apply_file() {
  node -e '
    const fs = require("fs");
    const path = require("path");
    const field = process.argv[1], dest = process.argv[2], mode = process.argv[3];
    const it = JSON.parse(fs.readFileSync(0, "utf8"));
    const f = (it.fields || []).find((x) => x.name === field);
    if (!f || f.value == null || String(f.value) === "") process.exit(3);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const tmp = dest + ".tmp." + process.pid;
    fs.writeFileSync(tmp, String(f.value), { mode: parseInt(mode, 8) });
    fs.renameSync(tmp, dest);
  ' "$1" "$2" "$3"
}

# Procesa una seccion del mapa. $1 = seccion ("global"|"prod") · $2 = folderid.
process_section() {
  local section="$1" folderid="$2"
  local as item field dest exp mode itemjson
  while IFS=$'\037' read -r as item field dest exp mode; do
    [ -n "$item" ] || continue
    itemjson="$(fetch_item "$item" "$folderid")"
    if [ -z "$itemjson" ]; then
      echo "  -- sin acceso a '$item'"
      continue
    fi
    dest="$(expand_path "$dest")"
    case "$as" in
      env)
        if printf '%s' "$itemjson" | apply_env "$field" "$dest" "$exp"; then
          echo "  OK $field -> $dest"
        else
          echo "  -- '$item'.$field vacio"
        fi
        ;;
      envfile)
        if printf '%s' "$itemjson" | apply_envfile "$dest"; then
          echo "  OK $item -> $dest (envfile)"
        else
          echo "  -- '$item' sin campos"
        fi
        ;;
      file)
        # mode acotado: solo lectura/escritura de dueño (y a lo sumo lectura de
        # grupo/otros). Nada de ejecucion ni setuid — un archivo de secreto no
        # los necesita, y el mapa es versionado (evita un mode peligroso por PR).
        case "$mode" in
          400|440|600|640|644|660) : ;;
          *) echo "  -- mode '$mode' no permitido para '$item' (usá 400/600/640/644)"; continue ;;
        esac
        if printf '%s' "$itemjson" | apply_file "$field" "$dest" "$mode"; then
          echo "  OK $field -> $dest (file, $mode)"
        else
          echo "  -- '$item'.$field vacio"
        fi
        ;;
      *)
        echo "  -- tipo 'as' desconocido: '$as' (item '$item')"
        ;;
    esac
  done < <(map_section "$section")
}

# ── Materializacion ──────────────────────────────────────────────────────────
echo "== globales =="
process_section "global" ""

if [ "$WITH_PROD" = "1" ]; then
  echo "== prod (solo operador) =="
  FOLDER_ID="$(folder_id "$APP")"
  if [ -z "$FOLDER_ID" ]; then
    echo "  -- sin carpeta '$APP' en el vault: no puedo desambiguar los items de prod" >&2
  else
    process_section "prod" "$FOLDER_ID"
  fi
fi

echo ""
echo "Listo. Cerra el acceso al vault con: bw lock"
