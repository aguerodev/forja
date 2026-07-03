---
id: ops.onboarding-secretos
titulo: Onboarding de secretos (gestor del equipo)
tipo: how-to
tier: 3
audience: both
resumen: Runbook por developer para recibir los secretos del equipo desde el gestor (Bitwarden CLI) sin que nadie se pase archivos: instalar bw, apuntar al server del equipo, que EL HUMANO desbloquee a BW_SESSION y correr scripts/materialize-secrets.sh. Incluye la frontera humano/agente, las reglas duras, los gotchas y el bootstrap del vault.
provides:
  - "runbook de onboarding de secretos por developer (instalar bw, apuntar al server, desbloquear BW_SESSION, materializar)"
  - "~/.bw_secrets (archivo local del gestor fuera del repo, chmod 600, custodiado por EL HUMANO, jamás a git ni al agente)"
  - "BW_SESSION heredado del entorno (nunca --session por argumento: aparecería en ps)"
  - "mapa declarativo secrets/secrets-map.json (versionado, sin valores; entradas as env|envfile|file)"
  - "scripts/materialize-secrets.sh (materializa el mapa desde el gestor; --prod agrega los items del proyecto)"
  - "búsqueda por carpeta del vault (folder == app de .forja.json) para desambiguar los items de prod"
  - "bootstrap del vault de secretos (import de JSON de Bitwarden una vez / bw create por API)"
  - "gotcha de la papelera de bw (los borrados van a papelera: verificar bw list items y --trash)"
  - "token de servicios de hooks en ~/.zshenv y no ~/.zshrc (los hooks corren en shells no interactivos)"
reads-before: [ops.secretos]
related: [ops.secretos]
---

# Onboarding de secretos (gestor del equipo)

Cuando entrás al proyecto necesitás los secretos del equipo en tu máquina —las API keys globales y, si sos operador, los de prod—. **No se pasan por chat ni por archivos:** la única copia compartida vive cifrada en el **gestor de secretos del equipo** (Bitwarden CLI) y vos la **materializás** localmente con un comando. Esta guía es el runbook: al terminar tenés tus secretos en su lugar sin que ningún valor haya tocado git ni la memoria.

El modelo y el porqué (los tres canales `engram`/gestor/`git`, global vs proyecto, el anti-patrón engram) están en [Secretos](./07_referencia-secretos.md). Acá está el **procedimiento**.

Asume que ya tenés:

- El repositorio clonado y confiado (el plugin forja activo).
- Una cuenta en el gestor del equipo (te la crea quien administra el vault) y la URL del server.
- `bw` y `node` instalables en tu máquina (`node` ya viene con el stack de desarrollo).

---

## Norma

La regla portable: **quién** puede tocar la master password y **qué** puede hacer un agente con el vault ya desbloqueado.

### El principio rector

> **`engram` = el saber · el gestor = el secreto · `git` = el código.**

El valor de un secreto vive **solo** en el gestor. Engram guarda el saber *sobre* el secreto (que existe, dónde va, cómo se rota), nunca su valor; git guarda el código y el mapa declarativo, nunca los valores. Cruzarlos es la fuga.

### La frontera humano / agente

La master password es el único eslabón que **jamás** delega el humano. El agente opera con un `BW_SESSION` ya desbloqueado y devuelto por el humano; nunca ve la master ni la persiste.

| Acción | Humano | Agente |
| --- | :---: | :---: |
| Custodiar y tipear la **master password** | ✅ | ❌ nunca la ve |
| Crear/editar `~/.bw_secrets` (credenciales del gestor) | ✅ | ❌ nunca lo toca |
| `bw login` / `bw config server` | ✅ | ❌ |
| `bw unlock` → exportar `BW_SESSION` | ✅ lo ejecuta | opera con el resultado |
| Correr `scripts/materialize-secrets.sh` | puede | ✅ con `BW_SESSION` ya en el entorno |
| `bw lock` al terminar | ✅ | ✅ |

### Reglas duras

- **`~/.bw_secrets` vive fuera del repo, con `chmod 600`, y JAMÁS llega a git.** Es donde EL HUMANO custodia lo necesario para desbloquear el gestor (email + master). Lo crea el humano con `umask 077`; el agente nunca lo crea ni lo lee.
- **Ningún secreto en engram ni en git.** El único lugar de un valor es el gestor. El mapa (`secrets/secrets-map.json`) se commitea porque **no contiene valores**; los `secrets/*.env` están gitignoreados.
- **`BW_SESSION` se hereda del entorno, nunca se pasa por `--session`.** Un `bw ... --session "$VALOR"` deja el token de sesión expuesto en `ps` y en el historial del shell. `bw` lo lee del entorno: exportalo y confiá en la herencia.
- **El agente nunca desbloquea el vault.** Si no hay `BW_SESSION`, para y pedile al humano que desbloquee; no intentes tipear ni adivinar la master.

---

## Camino verificado

Runbook por developer. Los pasos 1–4 los hace **el humano**; el 5 puede correrlo el agente con el `BW_SESSION` ya seteado.

### 1. Instalar el `bw` CLI

```bash
brew install bitwarden-cli   # macOS
# o, multiplataforma:
npm install -g @bitwarden/cli
bw --version
```

### 2. Apuntar al server del equipo

Antes del primer login, fijá el server (self-hosted del equipo o `bitwarden.com`). Se hace **una sola vez** por máquina:

```bash
bw config server https://<server-del-equipo>
```

### 3. EL HUMANO crea `~/.bw_secrets` e inicia sesión

El humano custodia sus credenciales del gestor en un archivo local, fuera del repo y con permisos cerrados. **Nunca el agente.**

```bash
umask 077
: > ~/.bw_secrets           # crear vacío con permisos 600 por el umask
chmod 600 ~/.bw_secrets     # explícito, por las dudas
# guardá ahí email + master (o el helper de unlock que uses); jamás en git
bw login <tu-email>         # pide la master de forma interactiva
```

### 4. Desbloquear a `BW_SESSION`

La master la tipea el humano; el resultado —un token de sesión efímero— es lo único que el agente puede usar. Se **exporta** al entorno para que `bw` lo herede:

```bash
export BW_SESSION="$(bw unlock --raw)"
```

A partir de acá, ningún comando `bw` lleva `--session`: todos heredan `BW_SESSION` del entorno.

### 5. Materializar los secretos

```bash
./scripts/materialize-secrets.sh          # solo globales (todo developer)
./scripts/materialize-secrets.sh --prod   # globales + prod (solo operador)
```

El script lee `secrets/secrets-map.json`, resuelve cada item en el gestor —los de `prod` dentro de la carpeta del vault cuyo nombre es el `app` de `.forja.json`— y escribe cada valor en su destino local (`upsert` idempotente en los `.env`, escritura atómica con `chmod 600` para los archivos completos). Es idempotente: volver a correrlo no rompe nada.

### 6. Cerrar el acceso

Al terminar, bloqueá el vault para que el `BW_SESSION` deje de servir:

```bash
bw lock
```

---

### El mapa declarativo, en una línea

`secrets/secrets-map.json` (versionado, **sin valores**) declara qué materializa el proyecto. Cada entrada tiene un `as`:

- `env` — `upsert` de `KEY=value` (o `export KEY="value"` con `"export": true`) en `dest`, keyed por `field`. Para globales (`~/.zshenv`, `~/.cf_provision.env`).
- `envfile` — vuelca **todos** los campos del item como líneas `key=value` en `dest` (materializa `secrets/prod.env` entero).
- `file` — escribe el valor de `field` en `dest` con permisos `mode` (p. ej. la clave SSH del backup). `${APP}` y un `~` inicial se expanden.

Se adapta editando el mapa, no el script. Plantilla de arranque: `secrets.skel/secrets-map.json`.

---

### Bootstrap del vault (una sola vez)

Antes de que alguien materialice, hay que **poblar** el vault. Es una tarea de arranque, no del runbook diario, y no la automatiza el script:

- **Import de JSON de Bitwarden.** Generá un JSON de export de Bitwarden desde las fuentes locales existentes (`secrets/prod.env`, `~/.cf_provision.env`, la clave del backup) e importalo con `bw import bitwardenjson <archivo>`. Borrá el JSON en claro apenas termine.
- **`bw create` por API.** Alternativa programática: crear items y campos con `bw create item` desde un objeto codificado en base64. Útil para reproducir el vault sin un archivo intermedio.

**Organización esperada** (la que el script asume):

- **Globales** en la raíz, **sin carpeta**: `Cloudflare API token`, `engram-cloud token`, cada uno con su campo hidden.
- **Del proyecto** en una **carpeta cuyo nombre es el `app`** de `.forja.json`: `prod secrets` (un item con los N campos de `secrets/prod.env`), `backup dedicated SSH key`.

---

### Gotchas

- **Los borrados van a la papelera, no desaparecen.** Tras una limpieza o consolidación de items, verificá **las dos** listas: `bw list items` **y** `bw list items --trash`. Un item puede quedar en papelera por un desfase de sync y hacerte creer que se borró. Se recupera con `bw restore item <id>`.
- **El token de servicios que consumen los hooks va en `~/.zshenv`, no `~/.zshrc`.** Los hooks de forja corren en shells **no interactivos**, y `~/.zshrc` solo se carga en shells interactivos: un token puesto ahí no lo ve el hook. Por eso `engram-cloud token` se materializa en `~/.zshenv` (con `export`).
