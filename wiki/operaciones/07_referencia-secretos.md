---
id: ops.secretos
titulo: Secretos
tipo: referencia
tier: 3
audience: both
resumen: Ciclo de vida del Docker secret, el contrato de nombre target = clave del schema de config, y el procedimiento de rotación.
provides:
  - "Docker secret (cifrado en el swarm, montado en /run/secrets, nunca env ni horneado en la imagen)"
  - "secrets/<env>.env (fuente local gitignored)"
  - "convención de nombre ${STACK}_<clave en minúscula>"
  - "contrato de nombre (secret.target = clave del campo en el schema de config de la app)"
  - "external:true en compose / deploy.sh crea el secret solo si no existe (idempotencia)"
  - "inmutabilidad del secret (docker secret rm + recreate para rotar)"
  - "el host de la DB en la cadena de conexión es el nombre de servicio (no localhost)"
  - "procedimiento de rotación"
  - "nombre corto (target) vs nombre completo (<stack>_<nombre>)"
  - "chequeo por estado del spec (no por sleep temporizado)"
  - "compartición de secretos del equipo vía gestor (materialización local, no compartir archivos; global sin carpeta vs proyecto con carpeta = app)"
  - "anti-patrón de anotar secretos en engram (sincroniza a un server compartido y commitea chunks a git: fuga al equipo y al historial)"
reads-before: [ops.modelo-operacion]
related: [ops.onboarding-secretos]
---

# Secretos

Los secretos viven **cifrados en el swarm** (en reposo y en tránsito) y se montan como **archivos en `/run/secrets/`** dentro del contenedor; nunca como variable de entorno horneada ni dentro de la imagen. Modelo de despliegue que da contexto (inmutabilidad, prefijo por stack, ubicación física en el raft del Swarm): [Modelo de operación](./01_explicacion-modelo-operacion.md).

---

## Norma

La regla portable: qué es un secret, cómo se nombra y por qué esa convención habilita un loader trivial.

### El flujo, de la fuente local al campo de `config`

- **Fuente local, gitignored.** Los valores viven solo en `secrets/<env>.env` (en `.gitignore`), respaldados fuera de git (gestor de contraseñas). Si se pierde tu máquina, se pierden los secretos.
- **Materialización.** `deploy.sh` lee `secrets/<env>.env` y crea un Docker secret por cada línea, con el nombre `${STACK}_<clave_en_minuscula>`, **solo si no existe** (los secrets son inmutables). Esta creación condicional es lo que hace al deploy idempotente.
- **Montaje.** El `stack.yml` referencia esos secrets como `external: true` y los monta con un `target` (el nombre del archivo en `/run/secrets/`). El secret `${STACK}_<clave>` se monta como `/run/secrets/<clave>`.
- **Lectura.** El módulo `config` de la app (un schema validado que lee `/run/secrets`) toma `/run/secrets/<clave>` y lo valida contra el campo `<clave>` del schema.

### Compartición entre developers: el gestor del equipo

La fuente local (`secrets/<env>.env`, `~/.cf_provision.env`) resuelve *tu* máquina, pero no responde una pregunta de equipo: **cuando entra un developer nuevo, ¿de dónde saca los secretos?** No se los pasás por chat de a uno ni le mandás tus archivos. El canal es un **gestor de secretos del equipo** (Bitwarden CLI): la única copia compartida vive cifrada ahí, y cada quien la **materializa** en su máquina.

El principio rector reparte tres canales que nunca se cruzan:

> **`engram` = el saber · el gestor = el secreto · `git` = el código.**

Cada cosa viaja por su carril. El conocimiento (decisiones, gotchas) va a engram; el código va a git; **el valor de un secreto vive SOLO en el gestor**. Mezclarlos es la fuga.

**Dos alcances, por cómo se organiza el vault:**

- **Global (sin carpeta).** API keys compartidas entre proyectos: el token de Cloudflare, el de engram-cloud. Items con nombre estable en la raíz del vault, sin carpeta. Se materializan siempre.
- **Del proyecto (carpeta = `app`).** Secretos específicos: `secrets/prod.env`, la clave SSH del backup. Viven en la carpeta del vault cuyo nombre es el `app` de `.forja.json`. La carpeta desambigua items homónimos entre proyectos y acota el acceso al que corresponde.

**Materialización, no compartir archivos.** Nadie envía su `secrets/prod.env` por un canal lateral. El equipo declara *qué* materializa en un mapa versionado y **sin valores** —`secrets/secrets-map.json` (`{ item, field, dest, as }`)— y un script (`scripts/materialize-secrets.sh`) lo lee del gestor en runtime y lo escribe en su lugar local. El mapa se commitea; los valores nunca. El runbook por developer, la frontera humano/agente y el bootstrap del vault están en [Onboarding de secretos](./13_how-to-onboarding-secretos.md).

**ANTI-PATRÓN — PROHIBIDO anotar un secreto en engram.** Un token, una contraseña, una clave privada: **nunca** en una observación de memoria. La memoria de equipo sincroniza a un server compartido **y** commitea sus chunks a `.engram/` en git — anotar una credencial ahí la filtra por partida doble: al equipo entero y al historial de git, los dos lugares de los que un secreto no se borra de verdad. Engram guarda el **saber sobre** el secreto (que existe, dónde vive, cómo rotarlo), jamás su valor. El valor solo en el gestor. (engram redacta lo envuelto en `<private>…</private>`, pero esa red no es una licencia para tipear secretos: la regla es no escribirlos.)

### El contrato de nombre

**El nombre del secret (su `target`) = la clave del campo en el schema de config de la app.** El loader recorre los archivos de `/run/secrets/` y arma el objeto con la clave igual al nombre de archivo, sin transformar. No hay tabla de mapeo entre nombres de secret y campos de config: el nombre ES el contrato. El patrón concreto del módulo de config es doctrina del stack de cada proyecto.

Distinción clave que reaparece en la rotación:

- **Nombre corto (`target`):** la clave del campo, el nombre del archivo en `/run/secrets/`. Ejemplo: `<clave-secret>`.
- **Nombre completo:** `${STACK}_<clave-secret>`, el identificador del secret dentro del Swarm.

### Las migraciones resuelven la conexión con el mismo contrato de dos fuentes

El tooling de migraciones del stack resuelve la URL de la base con el mismo contrato de dos fuentes que el módulo de config: primero la variable de entorno `DATABASE_URL`, después el secret montado en `/run/secrets/db_url` (y ninguna cuando una operación no necesita conexión viva).

Las dos fuentes existen porque hay dos consumidores: el CI y el dev local pasan `DATABASE_URL` como variable de entorno; el one-shot de migración del Swarm lee el secret montado. No hay segunda fuente de verdad para las credenciales: ambas rutas terminan en el mismo valor que consume la app.

### Reglas adicionales

- **El host de la DB en la cadena de conexión es el nombre del servicio** (por ejemplo `db`), no `localhost`. El usuario/clave deben coincidir con las variables `POSTGRES_USER` / `POSTGRES_PASSWORD` del compose.
- **Inmutabilidad.** Un Docker secret no se edita en el lugar. Para cambiar su valor hay que quitarlo de los servicios, borrarlo y recrearlo (ver [Camino verificado](#camino-verificado)).
- **Los tokens son sensibles por igual.** Cualquiera con el token de un túnel o una API key puede usarlo; se trata con el mismo cuidado que cualquier otro secreto.

### Dos clases de secreto: del runtime y de automatización

No todo secreto es un Docker secret. Hay dos clases con ciclos de vida distintos:

- **Secretos del runtime (Docker secrets).** Los que la app consume en ejecución (URL de la base, `tunnel_token`). Viven cifrados en el Swarm, se montan en `/run/secrets/` y siguen todo lo anterior (fuente local en `secrets/<env>.env`, inmutabilidad, prefijo por stack).
- **Secretos de automatización (tokens de control).** Credenciales con las que el **operador o el pipeline de CI** aprovisionan y gestionan la infraestructura *desde afuera* del nodo. No los consume ningún contenedor; los consume el plano de control. El precedente es el [token acotado de Cloudflare](./05_how-to-exponer-cloudflare-tunnel.md#por-qué-un-token-con-scope-y-no-la-global-api-key): vive en un archivo local fuera del repositorio (`~/.cf_provision.env`, permisos `600`, `source` por comando), nunca en el nodo. Los tokens de la API de Hetzner extienden ese precedente.

### Los dos tokens de la API de Hetzner (`hcloud`)

La gestión del servidor vía la API de Hetzner (ver [Gestionar la infra vía API](./12_how-to-gestionar-infra-via-api.md)) usa un token que es **secreto de automatización del operador/CI, NO un Docker secret del nodo**. La distinción es deliberada y no negociable: **el nodo gestionado es justo lo que el token puede destruir**. Montar el token Read&Write como Docker secret en ese mismo nodo significa que un RCE en cualquier contenedor entregaría la capacidad de borrar toda la infraestructura del proyecto. Por eso el token vive donde corre el aprovisionamiento (workstation del operador o runner de CI), nunca en el servidor que administra.

A diferencia del token de Cloudflare —que se acota por permiso (`Tunnel:Edit`, `DNS:Edit`, `Zone:Read`)—, el token de Hetzner **no tiene scope fino**: se emite por proyecto y solo admite dos niveles, **Read** o **Read&Write**. El mínimo privilegio no se logra por scope, sino segregando en **dos tokens distintos**:

- **Token `hcloud` READ** (default del loop autónomo). Permite listar, describir, derivar IP, leer métricas y `firewall describe`. No puede crear, destruir ni abrir puertos. Es el token con el que el agente opera por defecto. Puede vivir en el entorno del operador/CI con la misma disciplina de archivo local (`600`, fuera del repo, `source` por comando).
- **Token `hcloud` READ&WRITE** (break-glass, vaulted). Vive en el **gestor de secretos del equipo**, jamás en disco plano ni en el nodo. Se inyecta vía la variable de entorno `${HCLOUD_TOKEN}` (nunca como argumento de CLI: aparecería en `ps` y en el historial del shell) **solo** durante una operación mutadora explícitamente confirmada por un humano, y se descarta al terminar. Cubre `server create`, `firewall replace-rules`, resize y restore. Las operaciones destructivas siguen prohibidas a nivel API por `enable-protection delete rebuild`, independientemente del token.

Regla de blast radius: **prod vive en su propio proyecto Hetzner**, la única frontera dura que el proveedor ofrece. Cada proyecto aísla sus recursos y sus tokens.

### Ciclo de vida y rotación de los tokens `hcloud`

Los tokens de Hetzner **no expiran solos** ni se editan en el lugar: se rotan **por recreación** (mismo principio que la inmutabilidad del Docker secret, aplicado al plano de control). Se recrean en cadencia fija y, obligatoriamente, en el **offboarding** de cualquier operador que haya tenido acceso al token Read&Write. El procedimiento está en el [Camino verificado](#rotación-por-recreación-de-un-token-hcloud).

---

## Camino verificado

Procedimiento para **rotar** un secret existente en el Swarm sin rebuild ni redeploy completo. Como los secrets son inmutables, rotar = reemplazar.

### Antes de empezar

- Tenés el nuevo valor del secret.
- Conoces el **nombre corto** del campo (`<clave-secret>`): coincide con el nombre del archivo en `/run/secrets/` y con la clave `target` implícita en `stack.yml`.
- El **nombre completo** del secret en el Swarm es `${STACK}_<clave-secret>`.
- Tenés acceso al contexto Docker del entorno (`<ctx>`, por ejemplo `${APP}-prod` para el servidor o `<contexto-local>` para un Swarm local).

### 1. Quitar el secret del spec del servicio

```bash
docker -c <ctx> service update --secret-rm <clave-secret> ${STACK}_app
```

El argumento de `--secret-rm` es el **nombre corto** (el target del mount), no el nombre completo del secret en el Swarm. El servicio hace un rolling restart; las réplicas quedan sin ese secret montado.

### 2. Verificar que el secret ya no está referenciado en el spec

No avances al paso siguiente por timing. Verifica primero con este comando de estado:

```bash
docker -c <ctx> service inspect ${STACK}_app \
  --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{.SecretName}} {{end}}'
```

El nombre `${STACK}_<clave-secret>` no debe aparecer en la salida. Un `docker secret rm` sobre un secret todavía referenciado en el spec falla aunque el servicio no tenga réplicas activas. **La sincronización por tiempo (`sleep`) es poco fiable; el chequeo por estado del spec es el correcto.**

### 3. Borrar el secret

```bash
docker -c <ctx> secret rm ${STACK}_<clave-secret>
```

### 4. Crear el secret con el nuevo valor

```bash
printf '%s' "<nuevo-valor>" | docker -c <ctx> secret create ${STACK}_<clave-secret> -
```

Se crea por stdin para no dejar el valor en el historial del shell ni en un archivo intermedio.

### 5. Volver a montar el secret en el servicio

```bash
docker -c <ctx> service update \
  --secret-add source=${STACK}_<clave-secret>,target=<clave-secret> \
  ${STACK}_app
```

El servicio hace un rolling restart con el nuevo secret montado. No requiere rebuild de imagen.

### 6. Verificar dentro del contenedor

```bash
docker -c <ctx> exec <app_ctr> sh -c 'head -c 8 /run/secrets/<clave-secret>'
```

Los primeros caracteres deben corresponder al nuevo valor. Para obtener el ID del contenedor app:

```bash
docker -c <ctx> ps -q \
  --filter "label=com.docker.swarm.service.name=${STACK}_app" \
  --filter "status=running" | head -1
```

### 7. Actualizar `secrets/<env>.env`

`deploy.sh` crea secrets "si no existen" y nunca los actualiza. Si `secrets/<env>.env` mantiene el valor viejo, el próximo `./deploy.sh` lo omitirá sin error (el secret ya existe), pero la fuente local queda desincronizada. Actualiza el valor ahora para que la fuente de verdad local refleje el estado del Swarm.

### Rotación por recreación de un token `hcloud`

Los tokens de la API de Hetzner no se editan ni expiran: rotar = **crear uno nuevo, swapear, revocar el viejo**, sin ventana en la que el viejo y el nuevo no convivan. Aplica por separado al token READ y al token READ&WRITE. Cubre la cadencia fija y el offboarding del operador.

#### Antes de empezar

- Sabes qué token rotás (READ o READ&WRITE) y en qué proyecto Hetzner vive.
- Tenés acceso a la consola del proyecto (Hetzner solo permite crear/revocar tokens desde la consola, no por API).
- Para el token READ&WRITE: acceso al gestor de secretos del equipo. Para el token READ: acceso al archivo local del operador/CI.

#### 1. Crear el token nuevo en la consola

En la consola del proyecto Hetzner (*Security → API Tokens → Generate API Token*), creá un token con el **mismo nivel** que el que vas a reemplazar (Read o Read&Write). Copiá el valor una sola vez: Hetzner no lo vuelve a mostrar.

#### 2. Swapear el valor en su lugar de custodia

- **Token READ&WRITE:** actualizá la entrada en el gestor de secretos del equipo. No lo escribas en disco plano ni en el nodo. El próximo break-glass lo inyectará vía `${HCLOUD_TOKEN}`.
- **Token READ:** actualizá el archivo local del operador/CI (permisos `600`, fuera del repo), con el mismo cuidado que `~/.cf_provision.env`.

#### 3. Verificar que el token nuevo funciona

Con el token nuevo ya en su lugar, ejecutá una lectura inocua (blast radius cero) para confirmar que autentica antes de revocar el viejo:

```bash
HCLOUD_TOKEN="<token-nuevo>" hcloud server list -o json | jq 'length >= 0'
```

Debe devolver `true` sin error de autenticación. No avances a revocar hasta que esta verificación pase: revocar el viejo antes de validar el nuevo deja el plano de control sin credencial.

#### 4. Revocar el token viejo en la consola

Recién ahora, en la consola del proyecto, eliminá el token anterior. A partir de este punto solo el token nuevo es válido; cualquier copia residual del viejo queda inerte. Para un offboarding, este paso es el que efectivamente corta el acceso de la persona saliente.
