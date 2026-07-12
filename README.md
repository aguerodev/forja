# forja

Plugin de Claude Code con la **doctrina de ingeniería** del equipo (proceso + operaciones, agnóstica del stack) y el **bootstrap enterprise-grade** de proyectos nuevos: wiki de 19 documentos, skills, comandos de operador y guardias Gitflow para desarrollar con **gentle-ai** + **engram**.

La idea central: la doctrina **no se copia a cada proyecto** — viaja dentro del plugin y se consulta con la skill `forja:doctrina`. Un solo lugar para editarla, cero copias desincronizadas.

## Instalación

**Requisito:** [Claude Code](https://claude.com/claude-code) instalado. El repo es público, así que **no hace falta autenticación** para instalar el plugin.

Dentro de una sesión de Claude Code, corré estos dos comandos **uno a la vez** (cada uno en su propio prompt — NO los pegues juntos, se concatenan en un solo comando inválido):

**1. Registrá el marketplace** (lee `.claude-plugin/marketplace.json` de la rama `main`, la última versión estable):

```
/plugin marketplace add aguerodev/forja
```

> Si el shorthand `aguerodev/forja` te da error, usá la URL completa: `/plugin marketplace add https://github.com/aguerodev/forja.git`

**2. Instalá el plugin** (esperá a que el paso 1 confirme primero):

```
/plugin install forja@forja
```

**Verificá que quedó instalado:** corré `/forja:doctor` — debería listar el diagnóstico del entorno. Si escribís `/forja:` y aparecen `init`, `deploy`, `rollback`, `status`, `doctor`, `statusline` en el autocompletado, ya está.

### Tu primer proyecto

```
# 1. Entrá a tu proyecto (repo existente o carpeta vacía) y abrí Claude Code ahí
# 2. Dentro de la sesión:
/forja:init            # adopta el proyecto (o arranca uno nuevo): contrato .forja.json,
                       # scripts de release, Gitflow, settings — sin tocar tu código
# 3. Seguí los próximos pasos que imprime init (entrevista de requerimientos → SDD → deploy)
```

`/forja:init` deja el `.claude/settings.json` del proyecto apuntando a este marketplace, así que **cualquier compañero que clone el repo y abra Claude Code recibe el plugin sin instalar nada a mano** (Claude Code se lo ofrece al confiar la carpeta).

### Actualizar

```
/plugin marketplace update forja     # trae la última versión publicada en main
/plugin install forja@forja          # reinstala si hubo bump de versión
```

Herramientas del flujo (opcionales para instalar, necesarias para trabajar): **gh**, **engram** (MCP + CLI para memoria de equipo) y **gentle-ai** (SDD). El plugin instala sin ellas; `/forja:doctor` te dice cuáles faltan.

**Inteligencia de código (LSP):** forja **trae la config LSP de la capa de operación** (`.lsp.json`) — al instalar el plugin, Claude Code obtiene inteligencia de código para Bash y YAML (con schemas de compose y GitHub Actions). Los binarios de los servidores se instalan aparte (Claude Code no los baja): `npm install -g bash-language-server dockerfile-language-server-nodejs yaml-language-server` y, para los diagnósticos de bash, `brew install shellcheck shfmt`. `/forja:doctor` avisa cuáles faltan del PATH. Los language servers del stack de la app los define cada proyecto.

> **Límite conocido — Dockerfile:** el LSP de Claude Code matchea **solo por extensión con punto** (`.ts`, `.sh`), y el `Dockerfile` canónico no tiene extensión, así que su servidor **no engancha vía plugin-LSP** (sí matchea `*.dockerfile`). El binario `docker-langserver` igual se lista en `/forja:doctor` porque tu editor (que matchea por nombre de archivo) sí lo aprovecha.

## Qué recibe el equipo automáticamente

En un proyecto inicializado con `/forja:init`, `.claude/settings.json` referencia el marketplace forja: cada integrante que abra el repo con Claude Code recibe el plugin sin instalar nada a mano. Con eso llegan:

- **La doctrina completa** (`wiki/`, 3 tiers) consultable por recetas vía la skill `forja:doctrina` — nunca se lee entera.
- **Guardias activas** (hooks): en repos con `.forja.json` se bloquean commits/pushes directos a `main`/`develop`, la atribución de IA en commits y el uso crudo de la CLI de Hetzner. Fuera de proyectos forja, los hooks no hacen nada.
- **Contexto de sesión**: al abrir una sesión en un proyecto forja, el agente recibe un resumen del proyecto y sus reglas.
- **Memoria de equipo (engram git sync)**: la memoria del proyecto viaja por git — `.engram/` lleva los chunks committeados; al abrir sesión el hook corre `engram sync --import` (recibís lo del equipo) y al cerrar cada unidad de trabajo se corre `engram sync` y se commitea `.engram/` junto con el código. La DB local nunca entra al repo.
- **engram-cloud (recomendado para memoria de equipo)**: replicación de la memoria vía un [server self-hosted](https://github.com/Gentleman-Programming/engram/blob/main/docs/engram-cloud/README.md) que complementa el git-sync. Es **opcional pero fuertemente recomendado**: si no está configurado, `/forja:doctor` lo marca `WARN` y **la sesión te lo recuerda al arrancar** (nunca bloquea). Setup: `engram cloud config --server <url>` + `engram cloud enroll <project>`; `/forja:doctor` te dice qué falta.
- **Scripts de infra en el PATH** (`bin/`): `hcloud-agent.sh` (wrapper con allowlist y auditoría), `validate-firewall-rules.sh`, `infra-verify.sh`.

## Comandos

| Comando | Qué hace |
| --- | --- |
| `/forja:init [--force]` | Adopta un proyecto existente (default) o arranca uno nuevo: contrato `.forja.json`, scripts de release, Gitflow, GitHub. Nunca pisa archivos del proyecto. |
| `/forja:deploy preview\|production` | Release por fases con scripts deterministas, gates humanos y backup off-site. |
| `/forja:rollback preview\|production` | Volver a una versión sana; el plano datos es aparte y human-confirmed. |
| `/forja:status` | Solo lectura: quién está en qué, PRs abiertos, cambios SDD activos, slices libres. |
| `/forja:doctor` | Diagnóstico de herramientas y conformidad del proyecto, con remediaciones. |
| `/forja:statusline` | Instala la statusline de forja en `~/.claude` (dir │ rama │ modelo │ contexto% │ estado git). El arranque la sugiere si no la tenés. |

## Skills

- **`forja:doctrina`** — protocolo de consulta de la wiki: MANIFIESTO → receta por tarea → docs exactos en orden.
- **`forja:spec-doc-interviewer`** — entrevista que construye `software_requirements/` (PRD, glosario, requisitos, reglas, dominio) como insumo de gentle-ai. Decí "entrevistame".

## Loop de desarrollo del plugin

```bash
claude --plugin-dir .            # sesión con el plugin local montado
/reload-plugins                  # recargar tras editar comandos/skills/hooks
claude plugin validate . --strict        # gate de estructura
node wiki/_meta/validate-graph.mjs --check  # gate del grafo de doctrina
```

El repo del plugin **no usa GitHub Actions**: los gates corren localmente antes de cada release (el desarrollo del plugin no sigue las mismas reglas que el plugin impone a los proyectos).

## Saltear una guardia (solo humanos)

Las guardias aplican al **agente**, no a vos. Si sos humano, sabés lo que hacés y necesitás por ejemplo un push de emergencia: corré el comando en tu **terminal real**, fuera de Claude Code. Si te encontrás salteando una guardia seguido, el problema es el flujo — proponé cambiar la doctrina, no esquivarla en silencio.

## Layout del repo

```
.claude-plugin/   manifiestos del plugin y del marketplace
commands/         /forja:init, deploy, rollback, status, doctor
skills/           doctrina, spec-doc-interviewer
hooks/            hooks.json + scripts de guardia (bash-guard, session-context)
bin/              hcloud-agent.sh, validate-firewall-rules.sh, infra-verify.sh (entran al PATH)
scripts/          forja-instantiate.sh (instanciador determinista de /forja:init)
templates/        capa agnóstica de proyecto que instala /forja:init (adopt/new)
wiki/             la doctrina: 19 docs en 3 tiers + MANIFIESTO derivado
```

## Editar la doctrina

1. Editá los docs en `wiki/` (frontmatter incluido) en una rama.
2. Regenerá el índice: `node wiki/_meta/validate-graph.mjs --write` — el `MANIFIESTO.md` es un artefacto derivado, **nunca se edita a mano**.
3. Corré `node wiki/_meta/validate-graph.mjs --check` — falla si el MANIFIESTO quedó desincronizado — y abrí un PR a este repo.
