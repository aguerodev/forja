---
id: ops.backups
titulo: Backups
tipo: how-to
tier: 3
audience: both
resumen: Las dos capas de backup (pg_dump pre-migración y sidecar diario off-site al Storage Box) con sus procedimientos de restore.
provides:
  - "estrategia de backup en dos capas"
  - "backup pre-migración (pg_dump -Fc validado con pg_restore --list; aborta el deploy si no valida)"
  - "backup sidecar del stack (servicio backup en stack.yml: pg_dump diario validado, retención 7 rotando local + Storage Box, clave SSH dedicada)"
  - "restic + timer de systemd en el host (alternativa del dial al sidecar: append-only/WORM y multi-stack por host)"
  - "aprovisionar el Storage Box (la clave SSH nace antes que el box; puerto 23)"
  - "gotchas de acceso al Storage Box (se prueba desde el nodo; DNS sin propagar)"
  - "restore"
  - "regla un backup que nunca restauraste no es un backup"
  - "guarda de dump no vacío (pg_dump de cero bytes aborta la migración; un dump vacío no es respaldo)"
reads-before: [ops.secretos]
related: [ops.pipeline-cicd]
---

# Backups

Cómo se respalda y se recupera la base de datos de producción. Asume un stack desplegado con un servicio `db` (Postgres) y el secret de password montado en `/run/secrets/` ([manejo de secretos](./07_referencia-secretos.md)).

---

## Norma

La base de datos de producción se respalda en **dos capas independientes**, cada una con propósito distinto. Ninguna sustituye a la otra.

### Estrategia de backup en dos capas

- **Backup pre-migración (por cada deploy a prod).** Antes de aplicar cualquier migración, el release ejecuta un `pg_dump -Fc` **validado con `pg_restore --list`** que deja una copia local en la máquina del operador y se sube al Storage Box al cerrar el release. Punto de restore inmediato de cada deploy: si una migración sale mal, el estado anterior está a un comando de distancia. Se dispara en el paso de backup de [Release por comando](./08_how-to-pipeline-cicd.md); un dump que no valida **aborta el deploy** — un dump vacío o corrupto no es respaldo.
- **Backup diario retenido y off-site (sidecar del stack).** Cada stack lleva un servicio **`backup`**: un contenedor —de la **misma major de Postgres que `db`**, porque un `pg_dump` más viejo que el server no puede dumpearlo— cuyo script (`scripts/db-backup.sh`) hace `pg_dump -Fc` una vez al día, lo valida con `pg_restore --list`, guarda las **últimas 7 copias** en un volumen local del stack y sube cada dump al Storage Box por SFTP con una **clave SSH dedicada del sidecar** (secret `backup_ssh_key_b64`, en base64 porque un secret multilínea no viaja por el `.env`), rotando también el remoto a 7. Como viaja en `stack.yml`, **todo proyecto que despliega con esta metodología nace respaldado**: no hay cron por host que configurar ni que olvidar, y el respaldo no depende de que ocurran deploys. Un fallo de subida es WARN y reintenta al día siguiente (el dump local existe); la pérdida total del nodo la cubre la copia del box.

### Por qué dos capas y no una

- La capa **pre-migración** es de **grano fino y vida corta**: protege el instante exacto previo a cada cambio de schema. Vive cerca del deploy.
- La capa **off-site** es de **grano grueso y vida larga**: protege contra la pérdida del host completo. Vive fuera del nodo.

Un respaldo que solo existe en el mismo nodo que la base de datos no protege contra la pérdida del nodo; uno que solo existe en el momento del deploy no cubre la corrupción silenciosa entre releases.

### Destinos y su blast radius

No todo lo que parece copia protege contra lo mismo. Cada destino tiene un dominio de fallo distinto, y confundirlos es el error que deja sin recuperación:

| Destino | Qué protege | Blast radius | Quién lo gestiona |
|---|---|---|---|
| **Volume** (disco adicional del nodo) | nada respecto a backup: comparte el dominio de fallo del nodo | mismo nodo — si cae el server, cae con él | no es backup |
| **Snapshot / Backup del proveedor** (`create-image`, `--enable-backup`) | RTO: reconstrucción rápida de imagen/disco | MISMO proyecto y token de Hetzner — una llamada destructiva al proyecto lo borra junto al server | agente, solo additivo |
| **Off-site (sidecar → Storage Box por SFTP)** | RPO de negocio: única copia recuperable fuera del proveedor | proveedor/cuenta DISTINTA del proyecto Hetzner de prod | fuera de la API de Hetzner; credencial propia |
| **Apps** (imágenes inmutables tageadas por SHA + código en git) | el código se reconstruye, no se respalda | repositorio + registry | no es backup de datos |

La lección: el snapshot del proveedor es un atajo de RTO, no una copia recuperable. Si el único respaldo vive en el mismo proyecto Hetzner que el server, el peor modo de fallo (una sola llamada destructiva contra el proyecto) borra el server **y** su respaldo en el mismo gesto.

### Regla dura: el destino off-site vive FUERA del proyecto Hetzner de prod

El destino off-site (el Storage Box del sidecar, o el repositorio restic si el dial escaló) **debe** residir fuera del alcance del token del proyecto Hetzner de producción, idealmente en un proveedor o cuenta distinta. Razón: si server y backups comparten el radio de un mismo token, una sola operación destructiva los borra a ambos. La copia que justifica todo el esquema es precisamente la que ningún token de la infra de prod puede alcanzar. Compartir token entre el server y su respaldo anula el valor de tener respaldo.

### Qué puede tocar el agente y qué no

Cuando un agente de IA opera el plano de backups del proveedor vía la API de Hetzner, la frontera la fija el **daño irreversible**, no la intención del agente (matriz completa en [gestionar infraestructura vía API](./12_how-to-gestionar-infra-via-api.md)):

- **Autónomo additivo (el agente puede):** crear snapshots pre-cambio (`create-image --type snapshot`), habilitar backup del proveedor (`enable-backup`) y **verificar** frescura de respaldos (listar los dumps del volumen local y del Storage Box). Todo esto suma copias o las lee; no destruye nada y da rollback.
- **Human-gated (el agente NO puede):** `image delete`, `volume delete`, `disable-backup`, borrar dumps del box por fuera de la rotación del sidecar, y cualquier restore. Borran o degradan la única copia recuperable y quedan fuera del toolset del agente.

La clave dedicada del sidecar solo sube y rota los dumps de su propio stack en el box; no alcanza la infra ni el nodo. La disciplina **append-only** real —una credencial que agrega snapshots pero no puede podar, con el `forget --prune` separado y human-gated— pertenece a la escalación restic del dial (ver más abajo).

### Política de retención

El sidecar retiene las **últimas 7 copias diarias** (`BACKUP_KEEP=7`), rotando la más vieja tanto en el volumen local del stack como en el Storage Box; el dump pre-migración de cada release se suma aparte en `pre-migration/` del box. Una retención escalonada más larga (diarios + semanales + mensuales con `restic forget`) es parte de la escalación restic del dial (ver más abajo).

### El orden del aprovisionamiento: la clave SSH nace antes que el box

El Storage Box se aprovisiona en un orden preciso, y violarlo es la fuente clásica de una tarde perdida en `Permission denied`:

1. **Primero la clave, donde corre el backup.** La clave SSH dedicada se genera **antes** de crear el box, y se genera **donde el proceso de backup va a correr** (el nodo o el secret del sidecar) — nunca se reutiliza la clave de deploy del operador: esa privada vive en la máquina del operador, y el backup corre en el nodo, que no la tiene.
2. **El box se crea registrando esa clave pública**, con **SSH support** y **external reachability** activados. Registrar la clave en el momento de la creación evita el problema del huevo y la gallina (subir la clave por password a un box que aún no acepta conexiones).
3. **Se verifica desde el nodo, no desde la máquina del operador.** El SFTP del Storage Box va por el **puerto 23**, que muchas redes locales/ISP bloquean de salida; además, sin *external reachability* el box solo responde desde la red de Hetzner. Un "no funciona" probado desde la laptop no dice nada del box: la prueba válida es desde el nodo.

Corolario de diagnóstico: si el box rechaza **tanto** la clave como el password, el problema no es la red — es que la credencial está en otro box (verificar que el hostname `uNNNNNN` de la consola coincide con el box donde vive la clave) o que el password no es exacto.

### La regla que cierra todo

Un backup que nunca restauraste **no es un backup**. Probar una restauración cada tanto es parte del procedimiento, no opcional: la única garantía real de un respaldo es haberlo restaurado.

---

## Camino verificado

El procedimiento ejecutado, con parámetros parametrizados para cualquier proyecto.

### Aprovisionar el Storage Box (una vez por proyecto)

El orden importa (ver Norma). Verificado contra un Storage Box real de Hetzner:

```bash
# 1. Generar la clave dedicada EN EL NODO (o localmente si va al secret del sidecar).
ssh ${APP}-prod 'umask 077; ssh-keygen -t ed25519 -f ~/.ssh/storagebox -N "" -C "<app>-backup@prod"
                cat ~/.ssh/storagebox.pub'

# 2. En la consola de Hetzner: crear el Storage Box registrando ESA clave pública,
#    y activar "SSH support" y "External reachability" en su configuración.
#    Anotar el usuario/host resultante: uNNNNNN@uNNNNNN.your-storagebox.de

# 3. Verificar DESDE EL NODO (no desde la laptop: puerto 23 suele estar bloqueado ahí).
ssh ${APP}-prod 'echo "pwd" | sftp -i ~/.ssh/storagebox -P 23 \
  -o BatchMode=yes -o StrictHostKeyChecking=accept-new -b - uNNNNNN@uNNNNNN.your-storagebox.de'

# 4. Verificar ESCRITURA (un destino al que nunca escribiste no es un destino).
ssh ${APP}-prod 'echo ok > /tmp/sb_test.txt && printf "put /tmp/sb_test.txt\nls -l sb_test.txt\nrm sb_test.txt\n" \
  | sftp -i ~/.ssh/storagebox -P 23 -o BatchMode=yes -b - uNNNNNN@uNNNNNN.your-storagebox.de'
```

Notas del camino:

- **DNS de un box recién creado tarda en propagar.** Si el nodo no resuelve `uNNNNNN.your-storagebox.de` (pero `nslookup ... 1.1.1.1` sí), conectar por IP manteniendo la verificación de host key: `sftp -o HostKeyAlias=uNNNNNN.your-storagebox.de ... uNNNNNN@<IP>`. En cuanto propaga, se vuelve al hostname.
- **Puerto 23, no 22.** El SFTP/SSH del Storage Box escucha en el 23. Que el 22 responda no significa nada: no es tu servicio.
- Si el box se **recrea**, cambia el número `uNNNNNN` (hostname y usuario): re-registrar la clave y actualizar el secret `storage_box_dest` del sidecar.
- La clave del box es de **un solo uso**: solo sube backups. No es la clave de deploy ni da acceso al nodo.

### El sidecar de backup del stack

La implementación de referencia vive en el repo: stage `backup` del `Dockerfile` (FROM `postgres:<major-de-db>` + `openssh-client`, usuario sin privilegios), `scripts/db-backup.sh` (dump diario a las 03:30 UTC + una corrida inmediata al arrancar, validación con `pg_restore --list`, rotación local y remota a `BACKUP_KEEP=7`, subida por SFTP a `backups/<stack>/daily/` del box) y el servicio `backup` de `stack.yml` (volumen `dbbackups`, secrets `storage_box_dest` + `backup_ssh_key_b64`, anclado al manager junto a `db`). `deploy.sh` construye la imagen con `--target backup` y exige ambos secrets antes de tocar la base.

### DIAL: restic + timer de systemd en el host

El patrón anterior de esta doctrina —un `systemd .timer` en el host corriendo `pg_dump | restic backup` contra el repositorio off-site— queda como **escalación del dial**, no como base. Disparadores: necesitar **append-only real/deduplicación/cifrado del repositorio** (restic lo da; el SFTP plano del sidecar no), o varios stacks en un host que convenga respaldar con una sola maquinaria. Su forma verificada:

```bash
# /usr/local/bin/app-backup.sh  (lo dispara un systemd .timer diario)
#!/usr/bin/env bash
set -euo pipefail

# Destino off-site por SFTP y passphrase del repositorio restic.
export RESTIC_REPOSITORY="sftp:<usuario>@<host-off-site>:<puerto>/backups"
export RESTIC_PASSWORD_FILE=/etc/<app>/restic.pass   # chmod 600, fuera del repo

# Contenedor del servicio db del stack de prod.
DB_CID="$(docker ps -q -f name=${STACK}_db | head -n1)"

# pg_dump leyendo el password del secret montado en el contenedor,
# encadenado directo al backup restic por stdin.
docker exec -i "$DB_CID" sh -c \
  'PGPASSWORD="$(cat /run/secrets/<clave-password>)" pg_dump -h 127.0.0.1 -U <db-user> <db-name>' \
  | restic backup --stdin --stdin-filename db-prod.sql

# Aplicar la politica de retencion y liberar espacio.
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
```

Notas del camino:

- El repositorio restic se inicializa **una sola vez** contra el destino off-site (`restic init`) antes del primer backup.
- La passphrase (`restic.pass`) vive en el nodo con permisos `600` y **debe** existir también en la máquina del operador como parte de los secrets off-site: sin la passphrase, el repositorio es irrecuperable.
- El `pg_dump` corre **dentro** del contenedor `db` contra `127.0.0.1`, leyendo `PGPASSWORD` del secret montado; no expone el password en el entorno del host.
- El pipe directo `pg_dump | restic backup --stdin` evita escribir el dump completo a disco en el host.
- El backup diario es **append-only**: la credencial que usa el timer agrega snapshots pero no debe poder podar. El `restic forget --prune` (operación destructiva que recorta retención) se ejecuta con una **credencial separada** y queda human-gated, fuera del camino autónomo. Si un agente de IA opera la infra, puede crear y verificar snapshots, pero `forget`/`--prune`/`disable-backup` no están en su toolset: ver el límite agente vs humano en [gestionar infraestructura vía API](./12_how-to-gestionar-infra-via-api.md).

### El backup pre-migración

La fase 3 de `deploy.sh` (solo prod) genera el dump en formato custom y **aborta el deploy** si cualquier guarda falla:

```bash
# deploy.sh fase 3 — dump -Fc desde el contenedor db, validado antes de migrar.
docker exec "$db_cid" pg_dump -U <db-user> -Fc <db-name> > "backups/${STACK}_<timestamp>.dump"
# guarda: un dump que pg_restore no puede listar no es respaldo — abortar.
docker exec -i "$db_cid" pg_restore --list < "$dump" >/dev/null
```

Si el contenedor `db` no aparece tras esperar, si `pg_dump` falla o si el archivo no valida con `pg_restore --list`, el deploy **se corta ahí**: sin punto de restore no hay migración. El dump queda local en `backups/` y se sube a `pre-migration/` del Storage Box al cerrar el release.

### Cómo restaurar

- **Desde el dump pre-migración:** restaurar el `.dump` local (`backups/<stack>_*.dump`) con `pg_restore --clean --if-exists -d <base-objetivo>`. El archivo `-Fc` es binario: `psql` no puede leerlo; el restore es siempre con `pg_restore`.
- **Desde el diario del Storage Box (pérdida del nodo):** el punto de partida es la copia off-site de `secrets/prod.env`. De ahí se decodifica la clave dedicada del sidecar (`base64 -d` del valor de `backup_ssh_key_b64`, a un archivo con permisos `600`), se descarga el dump con `sftp -P 23 -i <clave>` desde `backups/<stack>/daily/` del box, y se aplica con `pg_restore --clean --if-exists` contra una base de PRUEBA primero.
- **Desde restic (si el dial escaló):** `restic restore` del snapshot deseado (`restic snapshots` para listarlos), recuperando `db-prod.sql` y aplicándolo con `psql` (el dump del dial es SQL plano).

En todos los casos, restaurar contra una base de prueba y verificar antes de tocar producción. Norma: un restore que nunca probaste no cuenta.

El escenario de pérdida total del nodo —el orden completo servidor → secrets → stack → datos— es el [runbook de recuperación ante desastre](./03_how-to-aprovisionar-servidor.md#runbook-de-recuperación-ante-desastre-nodo-único); esta sección cubre solo el plano de datos.
