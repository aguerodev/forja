# Deploy

- Desplegá a producción SOLO con el comando `/forja:deploy`, desde `main` limpio, al día con `origin/main` y con `pnpm run check` verde — NUNCA por CI ni corriendo `deploy.sh` a mano.
- GitHub Actions solo corre gates de PR (`check`, `integration`, `contract`; `mutation` nightly): el CI verifica, no despliega — ningún push, merge ni tag dispara un deploy.
- El tag `vX.Y.Z` es el REGISTRO del release, no un trigger: se corta después de verificar el deploy y su cuerpo anotado es el changelog.
- Aplicá expand/contract en toda migración destructiva: lo nuevo entra en un deploy, lo viejo se borra en un deploy POSTERIOR — durante el rolling conviven dos versiones del código contra el mismo esquema.
- El linter de migraciones (dentro de `pnpm run check`) bloquea las sentencias destructivas y non-expand por defecto: cada override (`-- migration:allow-destructive` / `-- migration:allow-non-expand`) es deliberado y lleva su razón al lado.
- Revertí con `/forja:rollback` distinguiendo los dos planos, sin mezclarlos jamás: software (barato, re-apunta la imagen, se ofrece de inmediato) y datos (`pg_restore` del dump pre-migración, destructivo y human-confirmed — borra todo lo escrito después del deploy).
- Cerrá cada release con el back-merge `main` → `develop` por PR.

Doctrina: wiki/operaciones/08_how-to-pipeline-cicd.md
