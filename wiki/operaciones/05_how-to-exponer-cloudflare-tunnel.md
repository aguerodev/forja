---
id: ops.exponer-tunnel
titulo: Exponer la app por Cloudflare Tunnel
tipo: how-to
tier: 3
audience: both
resumen: Provisionar el Cloudflare Tunnel por entorno vía API y las decisiones de modelo (conexión saliente, remotely-managed, token scoped, catch-all).
provides:
  - "Cloudflare Tunnel / cloudflared"
  - "provisión vía API de Cloudflare"
  - "token scoped"
  - "config_src cloudflare"
  - "ZONE_ID / ACCOUNT_ID derivados de la API"
  - "ingress hostname -> servicio"
  - "catch-all 404"
  - "CNAME proxied"
  - "TLS mode Full / etiqueta única con guion"
  - "un túnel por entorno"
  - "estados del túnel"
  - "cache de Cloudflare por URL fingerprinteada"
  - "~/.cf_provision.env / umask 077"
reads-before: [ops.modelo-operacion, ops.aprovisionar]
related: [proc.arrancar]
---

# Exponer la app por Cloudflare Tunnel

Expone una aplicación del Swarm a internet a través de un **Cloudflare Tunnel**, aprovisionado íntegramente desde la API de Cloudflare, sin abrir ningún puerto entrante en el servidor. El tráfico HTTP llega a Cloudflare y baja por un túnel **saliente** que `cloudflared` mantiene abierto; el firewall sigue dejando entrar solo SSH.

Crea **un túnel por entorno** (`prod` y `test`), cada uno con su token y su registro DNS. Todo se ejecuta **en tu máquina local** contra la API de Cloudflare; no toca el servidor.

Asume que ya tienes:

- Una zona (dominio) creada y en estado `active` en tu cuenta de Cloudflare.
- `jq` y `curl` instalados en tu máquina local.
- El servidor [aprovisionado](./03_how-to-aprovisionar-servidor.md) y [con el acceso endurecido](./04_how-to-endurecer-acceso.md): la aplicación corre (o correrá) como un servicio del Swarm llamado `app` en la red overlay `backend`, junto al `cloudflared` del mismo stack.
- Competencia básica con la línea de comandos y las APIs REST.

---

## Norma

Doctrina portable del modelo de exposición: el HTTP entra por un **túnel saliente** en vez de abrir puertos, y el porqué de cada decisión del aprovisionamiento por API.

### El giro: la app no escucha hacia afuera, sale a buscar a Cloudflare

Lo intuitivo es abrir un puerto: el servidor escucha en 80/443 y el mundo se conecta. Cada puerto abierto es superficie expuesta: algo que escanear, atacar, parchear y vigilar. Aquí el modelo se invierte: el servidor **no escucha** ningún puerto HTTP hacia afuera. El contenedor `cloudflared` —dentro del stack, en la red overlay `backend`— abre una conexión **saliente** hacia Cloudflare y la mantiene viva. El tráfico de usuarios llega a Cloudflare y desciende por ese túnel hasta la app; nunca toca un puerto entrante.

Consecuencia en el firewall: como no se publica ningún puerto de la app, `ufw` deja entrar solo el `22` (SSH) y cierra el resto. Mismo razonamiento que [por qué el firewall solo abre SSH](./04_how-to-endurecer-acceso.md); producción **no usa puertos publicados**. La superficie expuesta se reduce a una puerta: la clave SSH de `deploy`.

### Por qué túneles *remotely-managed*

Un túnel de Cloudflare guarda su configuración localmente (archivo que viaja con el conector) o **en Cloudflare** (*remotely-managed*, `config_src: "cloudflare"`). Se elige lo segundo por automatización: con la configuración en Cloudflare, `cloudflared` no necesita conocer el ingress, solo su **token**. El conector queda intercambiable y reproducible —se recrea, replica o mueve sin arrastrar archivos— y la definición del enrutamiento vive del lado de la API, aprovisionada una vez y versionada como datos. El contenedor se reduce a un proceso que se autentica con un token y abre el túnel.

### Por qué un token con *scope* y no la Global API Key

El aprovisionamiento usa un token de API **acotado**, nunca la Global API Key (secreto con poder total sobre la cuenta: si se filtra, se filtra todo). Un token con *scope* aplica **mínimo privilegio** y limita el daño de una fuga. Para crear túneles, configurar su ingress y manejar el DNS de la zona bastan tres permisos acotados a la zona específica:

- *Account · Cloudflare Tunnel · Edit*
- *Zone · DNS · Edit*
- *Zone · Zone · Read*

Así no puede tocar otras zonas ni otras áreas de la cuenta.

### Por qué `http://app:<puerto-app>` y no `localhost`

El ingress enruta el hostname a `http://app:<puerto-app>`, el **nombre de servicio** de la app, no a `localhost`; el puerto debe ser el mismo `PORT` que declara el servicio `app` en `stack.yml`. En el Swarm, `cloudflared` y la app son **contenedores distintos** en la overlay `backend`. `localhost` dentro de un contenedor significa *este mismo contenedor*: si `cloudflared` enrutara a `http://localhost:<puerto-app>` hablaría consigo mismo —donde no hay app escuchando— y fallaría. Debe dirigirse por el nombre de servicio `app`, que el DNS interno del Swarm resuelve al contenedor correcto dentro de la overlay. `localhost` nunca cruza ese límite.

### Por qué la regla catch-all `404` es obligatoria

Toda lista de ingress **debe** terminar con una regla sin hostname, el catch-all `{service: "http_status:404"}`; si falta, `cloudflared` **se niega a arrancar**. El ingress se evalúa en orden, y el conector necesita la garantía de que *cualquier* petición —incluso una que no coincida con ningún hostname— tiene destino. El catch-all captura lo que no encajó antes y responde `404` limpio en vez de dejar la petición sin ruta.

### Por qué el CNAME va *proxied*

El registro DNS que apunta el hostname al túnel se crea `proxied: true` (“nube naranja”), no DNS plano; es obligatorio. Con *proxied*, el tráfico pasa **a través de** Cloudflare antes de bajar por el túnel: Cloudflare termina el TLS, presenta el certificado y aplica WAF y CDN. El destino del CNAME, `<TUNNEL_ID>.cfargotunnel.com`, no es una dirección que el usuario resuelva directamente, sino la referencia interna que conecta el hostname con el túnel. Por eso el `ttl` se fija en `1` (automático): en modo *proxied* el TTL lo gobierna Cloudflare. Un CNAME en DNS plano (nube gris) saltaría todo esto y rompería el esquema.

### Por qué una etiqueta única con guion y no un subdominio multinivel

El entorno de prueba usa `dev-${APP}.<dominio>` —una etiqueta, con **guion**— y no `dev.${APP}.<dominio>` —dos niveles, con **punto**—, por costo. El Universal SSL gratuito de Cloudflare cubre el dominio raíz y **un nivel** de subdominio (`*.<dominio>`). `dev-${APP}` es una etiqueta bajo la raíz y cae dentro de ese comodín sin costo. `dev.${APP}.<dominio>` es subdominio de segundo nivel: el comodín no lo abarca, y cubrirlo con TLS exigiría un Advanced Certificate, con costo extra. (El prefijo literal `dev-` es convención; parametrízalo para tu caso.)

> En la zona, usa el modo SSL **Full** para que el TLS de extremo Cloudflare↔origen quede coherente con el túnel.

### Por qué un túnel por entorno

`prod` y `test` no comparten túnel: cada uno tiene el suyo, con su token, su ingress y su CNAME. Aunque corran en lugares distintos —`prod` en el servidor y `test` en el Swarm local de la máquina de desarrollo— quedan **aislados**: un cambio, una rotación de token o un problema en uno no arrastra al otro, y cada entorno expone solo su hostname. Costo: duplicar el aprovisionamiento. Ganancia: que no se pisan.

### Estados del túnel y errores esperables

- **`inactive`**: el túnel existe pero todavía no hay conector conectado (recién creado, antes del deploy). Es esperado.
- **Error 1033**: el túnel existe y el DNS resuelve, pero hay 0 conexiones activas (sin conector). Esperable hasta que el stack levante `cloudflared` con su token.
- **Error 1016**: el DNS no resuelve (CNAME ausente o mal apuntado).
- **502 / 530 transitorios**: aparecen mientras el conector establece o restablece la conexión.

Ninguno de estos indica un fallo del aprovisionamiento por sí solo; los dos primeros se resuelven al [desplegar el stack](./06_how-to-desplegar-swarm.md).

### Cache de Cloudflare: la URL pelada puede mostrar una versión vieja

Cloudflare cachea por defecto los assets estáticos que pasan por el túnel (bundles bajo `/_next/static/*` y archivos servidos desde `public/`). Verificar `curl https://<host>/<asset>` (URL sin fingerprint) puede devolver una copia cacheada que no refleja el último deploy, aunque el rollout haya completado con éxito y el nuevo archivo esté en el contenedor.

La verificación correcta usa la **URL fingerprinteada** que el browser realmente solicita. Next.js sirve sus bundles bajo `/_next/static/` con un **hash de contenido** incrustado en el nombre del archivo: cuando el contenido cambia, cambia el nombre, y Cloudflare lo trata como un recurso distinto que no puede servir desde cache. Para assets de `public/` que necesiten el mismo trato se versiona la referencia (`/<asset>?v=<hash>`, con el hash derivado del contenido del archivo). Un refresh normal del browser —sin hard-refresh— basta para que el usuario reciba el asset nuevo.

Alternativa: verificar directamente dentro del contenedor, evitando la cache por completo:

```bash
docker -c <ctx> exec <app_ctr> grep "<token>" /app/.next/static/<chunk>.js
```

Si el token aparece, el asset nuevo está desplegado, independientemente de lo que devuelva `curl` por la URL pelada. No corresponde levantar una falsa alarma de deploy fallido basándose solo en la respuesta de la URL sin versionar.

### Manejo del token

El `TUNNEL_TOKEN` autentica al conector contra Cloudflare: es un secreto real. **Nunca lo imprimas** en pantalla ni en logs. Guárdalo bajo `umask 077` con permisos `600`, materialízalo en `secrets/<env>.env` (cubierto por `.gitignore`) y respáldalo en un gestor de contraseñas. El archivo de credenciales de aprovisionamiento (`~/.cf_provision.env`) sigue la misma disciplina.

---

## Camino verificado

El procedimiento ejecutado, ya depurado. Comandos genéricos: parametriza `APP`, `BASE_DOMAIN` y `ENV` para tu caso. Recorre la guía una vez con `ENV=prod` y otra con `ENV=test`.

### Paso 1 — Preparar credenciales y derivar los IDs de cuenta y zona

Crea **una sola vez** un token de API con permisos acotados desde el panel de Cloudflare (*My Profile → API Tokens → Create Token*); Cloudflare no permite crear el primer token por API, así que es manual. Concede los tres permisos de mínimo privilegio descritos en la Norma y acota el alcance a tu zona específica. **Nunca uses la Global API Key.**

Guarda el token en un archivo **local, fuera del repositorio**, con permisos restringidos, que se hace `source` en cada comando (la shell puede no conservar las variables entre invocaciones):

```bash
umask 077
cat > ~/.cf_provision.env <<'EOF'
CF_API_TOKEN=<tu-token-con-scope>
BASE_DOMAIN=<dominio>
EOF
chmod 600 ~/.cf_provision.env
source ~/.cf_provision.env
```

Verifica que el token es válido y está activo:

```bash
curl -s "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer $CF_API_TOKEN" | jq '{success, status:.result.status}'
```

Debe devolver `success: true` y `status: "active"` (mensaje *“This API Token is valid and active”*).

Deriva el `ZONE_ID` y el `ACCOUNT_ID` de la propia API —no hace falta copiarlos del panel— y agrégalos al archivo de credenciales:

```bash
read ZONE_ID ACCOUNT_ID < <(curl -s \
  "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  | jq -r '.result[0] | "\(.id) \(.account.id)"')

cat >> ~/.cf_provision.env <<EOF
ZONE_ID=$ZONE_ID
ACCOUNT_ID=$ACCOUNT_ID
EOF
```

Confirma que la zona existe y está activa antes de seguir; si no, el registro DNS del Paso 5 fallará:

```bash
curl -s "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  | jq '.result[0] | {zone_id:.id, account_id:.account.id, status, name}'
```

Debe mostrar `status: "active"` con tu `zone_id`, `account_id` y `name`.

### Paso 2 — Fijar las variables del entorno

Define el entorno y deriva de él el hostname público y el nombre del túnel:

```bash
source ~/.cf_provision.env
APP="app"; ENV="prod"   # prod | test
case "$ENV" in
  prod) PUBLIC_HOST="${APP}.${BASE_DOMAIN}" ;;
  test) PUBLIC_HOST="dev-${APP}.${BASE_DOMAIN}" ;;
esac
TUNNEL_NAME="${APP}-${ENV}"
```

La convención de hostnames deriva del nombre de la app: `prod` → `${APP}.${BASE_DOMAIN}`, `test` → `dev-${APP}.${BASE_DOMAIN}`. El entorno de prueba usa la etiqueta única `dev-${APP}` (con guion, no punto) a propósito; el porqué está en la [Norma](#por-qué-una-etiqueta-única-con-guion-y-no-un-subdominio-multinivel).

### Paso 3 — Crear el túnel

Crea un túnel *remotely-managed* (`config_src: "cloudflare"`): su configuración de ingress vive en Cloudflare, de modo que el contenedor `cloudflared` solo necesitará el token para arrancar.

```bash
RESP="$(curl -s -X POST \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  --data "$(jq -n --arg n "$TUNNEL_NAME" '{name:$n, config_src:"cloudflare"}')")"
TUNNEL_ID="$(echo "$RESP" | jq -r '.result.id')"
TUNNEL_TOKEN="$(echo "$RESP" | jq -r '.result.token')"
```

La respuesta trae `success: true`, el identificador del túnel en `.result.id` y su token de conexión en `.result.token`. Guarda ambos en variables como arriba; **no imprimas `TUNNEL_TOKEN`** en pantalla ni en logs. Para recuperar el token más adelante, usa un `GET` al endpoint `.../cfd_tunnel/$TUNNEL_ID/token`.

### Paso 4 — Configurar el ingress (hostname → servicio)

Define a qué servicio enruta el túnel cada hostname. La regla apunta a `http://app:<puerto-app>` —el **nombre de servicio** de la app en la overlay `backend`, no `localhost`, con el `PORT` de `stack.yml`— y termina con un catch-all obligatorio:

```bash
curl -s -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  --data "$(jq -n --arg h "$PUBLIC_HOST" \
    '{config:{ingress:[{hostname:$h, service:"http://app:<puerto-app>"},{service:"http_status:404"}]}}')"
```

Debe devolver `success: true`. Toda lista de ingress **debe** terminar con la regla catch-all `{service:"http_status:404"}`; sin ella, `cloudflared` se niega a arrancar (ver [Norma](#por-qué-la-regla-catch-all-404-es-obligatoria)).

Confirma la configuración aplicada:

```bash
curl -s \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "Authorization: Bearer $CF_API_TOKEN" | jq '.result.config.ingress'
```

Para `prod` debe mostrar `[{"service":"http://app:<puerto-app>","hostname":"${APP}.<dominio>"},{"service":"http_status:404"}]`.

### Paso 5 — Crear el registro DNS (CNAME)

Apunta el hostname público al túnel mediante un CNAME *proxied* hacia `<TUNNEL_ID>.cfargotunnel.com`:

```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  --data "$(jq -n --arg h "$PUBLIC_HOST" --arg t "$TUNNEL_ID" \
    '{type:"CNAME", name:$h, content:($t + ".cfargotunnel.com"), proxied:true, ttl:1}')"
```

Debe devolver `success: true`. El registro va `proxied: true` (nube naranja) —obligatorio para que Cloudflare termine el TLS y aplique WAF/CDN— y `ttl: 1` (automático, exigido por el modo *proxied*). El porqué está en la [Norma](#por-qué-el-cname-va-proxied).

### Paso 6 — Guardar el token donde lo espera el despliegue

Materializa el token del túnel en el archivo que consume el despliegue, **sin imprimirlo nunca** en pantalla o log:

```bash
mkdir -p secrets
umask 077
touch "secrets/${ENV}.env" && chmod 600 "secrets/${ENV}.env"
# Append idempotente (misma disciplina que authorized_keys en el doc 04): nunca
# `>` sobre el .env — sobrescribir pisaría el resto de los secrets del archivo.
grep -q '^TUNNEL_TOKEN=' "secrets/${ENV}.env" \
  && echo "AVISO: TUNNEL_TOKEN ya existe en secrets/${ENV}.env — si rotaste el túnel, actualiza esa línea a mano" \
  || printf 'TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN" >> "secrets/${ENV}.env"
```

El `deploy.sh` lee ese `TUNNEL_TOKEN` y lo materializa como el Docker secret `${STACK}_tunnel_token`, que el `cloudflared` del compose monta en `/run/secrets/tunnel_token`. El patrón `secrets/*.env` está cubierto por `.gitignore`. Trátalo como secreto real: respáldalo en un gestor de contraseñas y no lo subas al repositorio.

### Paso 7 — Repetir para el otro entorno

Vuelve al Paso 2 con `ENV=test` y recorre los Pasos 3 a 6. Cada entorno obtiene **su propio túnel, su propio token y su propio CNAME**; `prod` y `test` quedan aislados y pueden correr en entornos separados (el servidor y tu máquina local).

### Paso 8 — Verificación final

Lista los túneles creados y revisa su estado:

```bash
curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel?is_deleted=false" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  | jq -r '.result[] | "\(.name)\t\(.id)\t\(.status)"'
```

Recién creados, ambos túneles aparecen con estado `inactive`: **es lo esperado** hasta que el stack levante `cloudflared` con su token y establezca el conector. Si visitas el hostname antes de ese momento, Cloudflare devuelve un **error 1033** (el túnel existe y el DNS resuelve, pero 0 conexiones activas); también es esperable. Ambos se resuelven al [desplegar el stack](./06_how-to-desplegar-swarm.md): al levantar `cloudflared` con su token, el túnel pasa a `healthy` y el hostname empieza a servir.

Confirma además que los archivos de secreto quedaron creados con permisos `600`:

```bash
ls -l secrets/prod.env secrets/test.env
```

---

## Lo que sigue

Con los túneles, el ingress, los CNAME y los tokens aprovisionados, el último paso es el **despliegue del stack**: levanta `cloudflared` con su `TUNNEL_TOKEN`, conecta el conector a Cloudflare y deja el hostname sirviendo.

- [Desplegar el stack en Swarm](./06_how-to-desplegar-swarm.md)
