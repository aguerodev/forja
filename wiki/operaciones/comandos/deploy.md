---
description: Deploy a preview (local) o production — preflight, backup off-site, verificación y registro
argument-hint: preview | production
disable-model-invocation: true
---

# /deploy $ARGUMENTS

Sos el operador de release. Cada fase es un **script determinista** en `scripts/release/` — vos NO improvisás comandos: ejecutás el script, mostrás su output y actuás según su **exit code**. Tu único juicio está en los gates humanos. Doctrina: `wiki/operaciones/08_how-to-pipeline-cicd.md`.

Contexto fijo en `scripts/release/lib.sh`. Si `$ARGUMENTS` está vacío, preguntá: ¿preview o production?

## Si el argumento es `preview`

Despliega al Swarm LOCAL (https://dev-shorter.automatiza.cc) para revisar el cambio en vivo. Sin gates de procedencia — preview existe justamente para probar trabajo en curso.

```bash
./deploy.sh test
STACK=app_shorter_test PUBLIC_HOST=dev-shorter.automatiza.cc bash scripts/release/verify.sh
```

- `verify.sh` compara contra el HEAD local; si el working tree tiene cambios sin commitear el SHA puede no coincidir — reportalo como nota, no como fallo del deploy.
- Al final mostrá la URL de preview y recordá que `/rollback preview` lista las versiones anteriores.

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
bash scripts/release/offsite-backup.sh   # dump al Storage Box vía el nodo (WARN si falta backup.env)
bash scripts/release/verify.sh           # SHA desplegado == HEAD + smoke
bash scripts/release/tag-release.sh      # tag git vX.Y.Z (registro, NO trigger; idempotente)
```

- `verify.sh` falla → el deploy sirvió otra cosa: ir a Fase 3.
- Cierre: guardar el release en memoria (engram) y recordar el back-merge `main → develop` (PR).

### Fase 3 — Ante un fallo

- **Recuperación inmediata**: correr `/rollback production` (vuelve a una versión anterior sana, código solamente; se regresa con `rollback-to.sh production latest`).
- **Plano datos** (migración que corrompió esquema/datos): DESTRUCTIVO — ver la sección de restore en `.claude/commands/rollback.md`; exige la confirmación literal `restaurar datos`.

## Reglas duras

- Jamás desplegar production si `preflight.sh` no salió 0, ni sin la confirmación literal `prod`.
- Si algo queda a medias (deploy parcial, migración colgada), NO reintentar a ciegas: diagnosticar con `docker -c myapp-prod stack ps app_shorter_prod` y `docker -c myapp-prod service logs app_shorter_prod_migrate`, reportar y proponer el paso siguiente.
