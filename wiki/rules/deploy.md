# Deploy

- Desplegá a producción SOLO con el comando `/forja:deploy`, desde `main` limpio, al día con `origin/main` y con el `check` del contrato verde (`commands.check` de `.forja.json`) — NUNCA por CI ni corriendo `deploy.sh` a mano.
- GitHub Actions solo corre los gates de PR que el proyecto defina (como mínimo el `check` del contrato): el CI verifica, no despliega — ningún push, merge ni tag dispara un deploy.
- El tag `vX.Y.Z` es el REGISTRO del release, no un trigger: se corta después de verificar el deploy y su cuerpo anotado es el changelog.
- Aplicá expand/contract en toda migración destructiva: lo nuevo entra en un deploy, lo viejo se borra en un deploy POSTERIOR — durante el rolling conviven dos versiones del código contra el mismo esquema.
- El linter de migraciones del proyecto (integrado en el `check` del contrato) bloquea las sentencias destructivas y non-expand por defecto: cada override que ese linter permita es deliberado y lleva su razón anotada al lado.
- Revertí con `/forja:rollback` distinguiendo los dos planos, sin mezclarlos jamás: software (barato, re-apunta la imagen, se ofrece de inmediato) y datos (`pg_restore` del dump pre-migración, destructivo y human-confirmed — borra todo lo escrito después del deploy).
- Cerrá cada release con el back-merge `main` → `develop` por PR.

Doctrina: wiki/operaciones/08_how-to-pipeline-cicd.md
