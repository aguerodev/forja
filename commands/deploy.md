---
description: Deploy a preview (local) o production - preflight, backup off-site, verificación y registro
argument-hint: preview | production
disable-model-invocation: true
---

# /forja:deploy $ARGUMENTS

Sos el operador de release. Cada fase es un **script determinista** en `scripts/release/` — vos NO improvisás comandos: ejecutás el script, mostrás su output y actuás según su **exit code**. Tu único juicio está en los gates humanos. Doctrina: skill `forja:doctrina`, receta `desplegar`.

Si `$ARGUMENTS` está vacío, preguntá: ¿preview o production?

## Contexto del proyecto (SIEMPRE primero)

Leé `.forja.json` en la raíz del repo. Si NO existe → decile al usuario que corra `/forja:init` (o cree `.forja.json` a mano) y **PARÁ acá**.

```bash
node -e '
const { execSync } = require("child_process");
const c = JSON.parse(require("fs").readFileSync(".forja.json", "utf8"));
let dev = "";
try { dev = execSync("git config --get forja.devUser", {stdio:["ignore","pipe","ignore"]}).toString().trim().toLowerCase(); } catch {}
console.log("APP=" + c.app);
console.log("STACK_TEST=" + c.app + "_test");
console.log("STACK_PROD=" + c.app + "_prod");
console.log("PREVIEW_HOST=" + (dev || "dev") + "-" + c.publicName + "." + c.domain);
console.log("PROD_HOST=" + c.publicName + "." + c.domain);
console.log("DOCKER_CONTEXT=" + c.dockerContext);
console.log("DB_USER=" + c.db.user);
console.log("DB_NAME=" + c.db.name);
'
```

El host de preview es **por developer**: el label sale de `git config forja.devUser` (lo setea `/forja:init`; fallback `dev` si falta). Cada dev tiene su Swarm local, su túnel y su hostname — no se pisan. Si `PREVIEW_HOST` salió con `dev-` y hay más de un developer en el proyecto, sugerí setear el label antes de aprovisionar el túnel: `git config --local forja.devUser <usuario-github>`.

Guardate estos valores: los bloques de abajo usan `$STACK_TEST`, `$PREVIEW_HOST`, `$STACK_PROD`, `$DOCKER_CONTEXT` como marcadores — **sustituilos por los valores derivados** al ejecutar (cada bloque de bash corre en un shell nuevo; las variables no persisten solas).

## Si el argumento es `preview`

Despliega al Swarm LOCAL (`https://$PREVIEW_HOST`) para revisar el cambio en vivo. Sin gates de procedencia — preview existe justamente para probar trabajo en curso.

```bash
./deploy.sh test
STACK=$STACK_TEST PUBLIC_HOST=$PREVIEW_HOST bash scripts/release/verify.sh
```

- `verify.sh` compara contra el HEAD local; si el working tree tiene cambios sin commitear el SHA puede no coincidir — reportalo como nota, no como fallo del deploy.
- Al final mostrá la URL de preview y recordá que `/forja:rollback preview` lista las versiones anteriores.

## Si el argumento es `production`

### Fase 0 — Preflight

```bash
bash scripts/release/preflight.sh
```

- Exit ≠ 0 → **ABORTAR** mostrando el `[FAIL]` (rama ≠ main, tree sucio, desfasado de origin, tag ya existente, `pnpm run check` rojo).
- Exit 0 → mostrar el **resumen del release** y pedir al usuario que escriba **`prod`** literal. Sin esa palabra NO hay deploy.

### Fase 1 — Deploy

```bash
./deploy.sh prod
```

Encadena: build → secrets (assert) → **pg_dump validado que aborta si falla** → stack deploy → migración one-shot gateada → health node-side (fatal) + edge (warn) → tags de rollback (`prod-<ts>`, `v<version>`).

- Aborta ANTES de la migración → no se tocó nada: reportar y terminar.
- Aborta EN la migración o el health → ir a Fase 3.

### Fase 2 — Off-site, verificación y registro (solo con deploy OK)

```bash
bash scripts/release/offsite-backup.sh   # dump off-site vía el sidecar de backup (RUN_ONCE=1; WARN si el sidecar o sus secrets faltan)
bash scripts/release/verify.sh           # SHA desplegado == HEAD + smoke
PUSH_TAG=1 bash scripts/release/tag-release.sh   # tag git vX.Y.Z + push a origin (el registro es COMPARTIDO; NO trigger; idempotente)
```

- `verify.sh` falla → el deploy sirvió otra cosa: ir a Fase 3.
- Cierre: guardar el release en memoria (engram) y recordar el back-merge `main → develop` (PR).

### Fase 3 — Ante un fallo

- **Recuperación inmediata**: correr `/forja:rollback production` (vuelve a una versión anterior sana, código solamente; se regresa con `rollback-to.sh production latest`).
- **Plano datos** (migración que corrompió esquema/datos): DESTRUCTIVO — ver la sección de restore de `/forja:rollback`; exige la confirmación literal `restaurar datos`.
- **Reportar el fallo** (mejora continua): si el fallo fue del propio flujo forja (script que no debería fallar, fase colgada, error inesperado), ofrecé abrir un reporte con la skill `report-failure` — junta el diagnóstico real, redacta datos sensibles y crea el issue SOLO con confirmación del usuario. Nunca automático.

## Reglas duras

- Jamás desplegar production si `preflight.sh` no salió 0, ni sin la confirmación literal `prod`.
- Si algo queda a medias (deploy parcial, migración colgada), NO reintentar a ciegas: diagnosticar con `docker -c $DOCKER_CONTEXT stack ps $STACK_PROD` y `docker -c $DOCKER_CONTEXT service logs ${STACK_PROD}_migrate`, reportar y proponer el paso siguiente.
