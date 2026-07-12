# Flujo de git (Gitflow)

- `main` es PRODUCCIÓN y está protegida por convención: NUNCA commitees ni pushees directo a `main` ni a `develop` — todo cambio entra por Pull Request.
- Usá `develop` como rama de integración y default del repo: el trabajo diario nace y vuelve ahí.
- Cortá cada cambio como `feature/<nombre>` desde `develop` y devolvelo a `develop` por PR; mantené las ramas de feature CORTAS — días, no semanas.
- El bump de la versión del proyecto (el dato que lee `commands.version` del contrato) va SOLO en `release/<versión>`, que sale de `develop` y entra a `main` por PR; sobre ese merge se corta el tag `vX.Y.Z` como registro del release.
- Usá `hotfix/<nombre>` solo para urgencias sobre producción: sale de `main` y vuelve a `main` Y a `develop`.
- Tras cada merge a `main` (release o hotfix), hacé el back-merge `main` → `develop` por PR — no es opcional: sin él, `develop` queda con la versión vieja y el próximo release nace mal numerado.
- No mergees ningún PR sin los gates verdes (el `check` del contrato, `commands.check`; local = CI).
- Solo `main` llega a producción, y el candado real es el preflight de `/forja:deploy`, no GitHub.

Doctrina: wiki/proceso/01_explicacion-trabajo-con-ia.md
