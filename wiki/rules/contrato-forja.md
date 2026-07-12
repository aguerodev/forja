# Contrato `.forja.json` (v2)

`.forja.json` es el contrato committeado que conecta el proyecto con el tooling forja: los comandos (`/forja:deploy`, `/forja:rollback`), los scripts de `scripts/release/` y los hooks leen SOLO este archivo. v2 es **aditivo sobre v1**: un archivo v1 sigue siendo válido tal cual, porque todo campo nuevo tiene un fallback definido y los lectores DEBEN implementarlo.

## Ejemplo v2

```json
{
  "app": "acme",
  "publicName": "acme",
  "domain": "example.com",
  "dockerContext": "acme-prod",
  "github": { "org": "acme-co", "repo": "acme" },
  "db": { "user": "acme", "name": "acme", "pgMajor": "17" },
  "commands": {
    "install": "pnpm install",
    "check": "pnpm run check",
    "test": "pnpm test:unit",
    "dev": "pnpm dev",
    "migrate": "pnpm drizzle-kit migrate",
    "version": "node -p \"require('./package.json').version\""
  },
  "runtime": {
    "port": 8000,
    "healthcheckPath": "/api/health",
    "healthcheckExec": ""
  }
}
```

## Campos

### Heredados de v1 (obligatorios, sin cambios)

| Campo | Qué es |
| --- | --- |
| `app` | Nombre corto de la aplicación; prefijo de los stacks Swarm (`<app>_prod`, `<app>_test`) |
| `publicName` | Subdominio público de producción (`<publicName>.<domain>`) |
| `domain` | Dominio raíz |
| `dockerContext` | Contexto Docker del nodo de producción |
| `github.org` / `github.repo` | Organización y repositorio en GitHub |
| `db.user` / `db.name` / `db.pgMajor` | Usuario, base y major de PostgreSQL |

### Legado v1 (opcional en v2)

| Campo | Qué es |
| --- | --- |
| `nodeVersion` | Versión de Node de la app. Solo tiene sentido en apps Node; los lectores no lo requieren. |

### Nuevos en v2 (opcionales, con fallback)

| Campo | Qué es |
| --- | --- |
| `commands.install` | Comando shell que instala dependencias |
| `commands.check` | Comando shell del gate de calidad (local = CI) |
| `commands.test` | Comando shell de los tests unitarios |
| `commands.dev` | Comando shell del server de desarrollo |
| `commands.migrate` | Comando shell que aplica migraciones |
| `commands.version` | Comando shell que imprime la versión del proyecto en stdout |
| `runtime.port` | Puerto interno donde escucha la app dentro del contenedor |
| `runtime.healthcheckPath` | Path HTTP del healthcheck (se sondea en `http://127.0.0.1:<port><path>`) |
| `runtime.healthcheckExec` | Comando shell que corre DENTRO del contenedor de la app como healthcheck; si está seteado, reemplaza el sondeo HTTP por path |

### Contrato de salida de `healthcheckExec`

Si definís `runtime.healthcheckExec`, el comando DEBE cumplir esto (deploy, verify y rollback dependen de ello):

- Imprimir en stdout el JSON de health de la app, **incluyendo `buildSha`** — los scripts parsean `buildSha` de ese cuerpo para verificar qué commit está corriendo.
- Salir con código 0 SOLO cuando la app está sana; cualquier otro estado sale distinto de 0 (idealmente imprimiendo igual el cuerpo de error — un 503 con `buildSha` sigue siendo diagnóstico útil).

## Reglas de fallback (obligatorias para todo lector)

Todo lector de `.forja.json` (scripts, comandos, hooks) DEBE aplicar exactamente estos defaults cuando el campo falta — así un archivo v1 se comporta idéntico a como se comportaba antes de v2:

| Campo ausente | Valor efectivo |
| --- | --- |
| `commands.install` | `pnpm install` |
| `commands.check` | `pnpm run check` |
| `commands.test` | `pnpm test:unit` |
| `commands.version` | `node -p "require('./package.json').version"` |
| `runtime` (completo o parcial) | `{ "port": 8000, "healthcheckPath": "/api/health" }` |
| `runtime.healthcheckExec` | vacío → se sondea por HTTP (`wget`, `curl` o `node` — lo que traiga la imagen) |

- Los `commands.*` son strings de shell: se ejecutan con `sh -c` desde la raíz del repo. Ningún lector interpreta su contenido.
- Un `runtime` parcial se completa campo a campo con los defaults (declarar solo `port` NO borra el `healthcheckPath` default).

## Semántica

- **v2 es aditivo.** Ningún campo v1 cambia de significado ni se elimina. Migrar un proyecto a v2 es agregar campos, nunca reescribir los existentes.
- **El runtime lee SOLO el `.forja.json` committeado.** El contrato viaja en el repo del proyecto: un deploy jamás depende de que el plugin esté instalado en la máquina ni de archivos fuera del repo.
- **Node es el runtime del tooling forja, no una opinión sobre el stack de la app.** Los hooks y scripts parsean JSON con `node` porque el tooling lo necesita en la máquina del operador; la app puede ser Go, Python o cualquier otro stack.

Doctrina: los lectores canónicos son `scripts/release/lib.sh` (contexto de los release scripts) y los bloques de contexto de `/forja:deploy` y `/forja:rollback`.
