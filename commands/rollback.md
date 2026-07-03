---
description: Rollback a una versión anterior en preview o production (código; el plano datos es aparte)
argument-hint: preview | production
disable-model-invocation: true
---

# /forja:rollback $ARGUMENTS

Volvés la app a una versión anteriormente desplegada y SANA. Scripts deterministas en `scripts/release/`; vos solo orquestás y pedís las confirmaciones. Si `$ARGUMENTS` está vacío, preguntá: ¿preview o production?

## Contexto del proyecto (SIEMPRE primero)

Leé `.forja.json` en la raíz del repo. Si NO existe → decile al usuario que corra `/forja:init` (o cree `.forja.json` a mano) y **PARÁ acá**.

```bash
node -e '
const c = JSON.parse(require("fs").readFileSync(".forja.json", "utf8"));
console.log("STACK_TEST=" + c.app + "_test");
console.log("STACK_PROD=" + c.app + "_prod");
console.log("DOCKER_CONTEXT=" + c.dockerContext);
console.log("DB_USER=" + c.db.user);
console.log("DB_NAME=" + c.db.name);
'
```

Los bloques de abajo usan `$STACK_PROD`, `$DOCKER_CONTEXT`, `$DB_USER`, `$DB_NAME` como marcadores — **sustituilos por los valores derivados** al ejecutar.

## Paso 1 — Listar versiones

```bash
bash scripts/release/versions.sh $ARGUMENTS
```

Cada versión sale con **el commit del que fue construida** (sha corto + mensaje) — esa es la descripción del cambio. Mostrá la lista (la `*` marca la corriendo) y preguntá **a cuál volver**. Si la lista está vacía, explicá que los tags se generan en cada deploy sano a partir de ahora.

## Paso 2 — Confirmar

- `preview`: basta con que el usuario elija el tag.
- `production`: mostrá el tag elegido y exigí que el usuario escriba **`rollback`** literal. Recordale: es CÓDIGO solamente — la base de datos queda como está (expand/contract garantiza compatibilidad).

## Paso 3 — Ejecutar

```bash
bash scripts/release/rollback-to.sh $ARGUMENTS <tag-elegido>
```

- Exit 0 → el script ya verificó health y muestra el build SHA corriendo.
- Exit ≠ 0 → mostrar el `[FAIL]` y diagnosticar con `docker stack ps <stack>` (agregando `-c $DOCKER_CONTEXT` si es production). Si el fallo fue del propio flujo forja (no del entorno del usuario), ofrecé reportarlo con la skill `report-failure` — diagnóstico redactado, issue solo con confirmación.

## Volver a la última versión

Cuando el usuario quiera regresar a la versión más reciente (deshacer el rollback):

```bash
bash scripts/release/rollback-to.sh $ARGUMENTS latest
```

Y recordá: **el próximo `/forja:deploy` también supera cualquier rollback** — un rollback es un puente mientras se corrige, no un estado permanente.

## Plano datos (SOLO production, DESTRUCTIVO, human-confirmed)

Restaurar el dump pre-migración BORRA todo lo escrito después de ese dump. Solo si una migración corrompió esquema o datos:

1. Explicar exactamente qué se pierde (ventana temporal desde el dump).
2. Exigir la confirmación literal **`restaurar datos`**.
3. Rollback del software primero (arriba), luego:

```bash
db_cid=$(docker -c $DOCKER_CONTEXT ps --filter "label=com.docker.swarm.service.name=${STACK_PROD}_db" --format '{{.ID}}' | head -1)
docker -c $DOCKER_CONTEXT exec -i "$db_cid" pg_restore -U $DB_USER -d $DB_NAME --clean --if-exists < backups/<dump-pre-migracion>.dump
```

4. Re-verificar: `EXPECTED_SHA=<sha-corriendo> bash scripts/release/verify.sh` + smoke.

Al cerrar cualquier rollback: guardá el evento en memoria (engram) — versión desde/hacia, motivo y próximos pasos.
