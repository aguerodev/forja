# forja

Plugin de Claude Code con la **doctrina de ingeniería** completa del equipo y el **bootstrap enterprise-grade** de proyectos nuevos: wiki de 28 documentos, skills, comandos de operador y guardias Gitflow para desarrollar con **gentle-ai** + **engram**.

La idea central: la doctrina **no se copia a cada proyecto** — viaja dentro del plugin y se consulta con la skill `forja:doctrina`. Un solo lugar para editarla, cero copias desincronizadas.

## Instalación

```
/plugin marketplace add aguerodev/forja
/plugin install forja@forja
```

## Qué recibe el equipo automáticamente

En un proyecto creado con `/forja:init`, `.claude/settings.json` referencia el marketplace forja: cada integrante que abra el repo con Claude Code recibe el plugin sin instalar nada a mano. Con eso llegan:

- **La doctrina completa** (`wiki/`, 4 tiers) consultable por recetas vía la skill `forja:doctrina` — nunca se lee entera.
- **Guardias activas** (hooks): en repos con `.forja.json` se bloquean commits/pushes directos a `main`/`develop`, la atribución de IA en commits y el uso crudo de la CLI de Hetzner. Fuera de proyectos forja, los hooks no hacen nada.
- **Contexto de sesión**: al abrir una sesión en un proyecto forja, el agente recibe un resumen del proyecto y sus reglas.
- **Scripts de infra en el PATH** (`bin/`): `hcloud-agent.sh` (wrapper con allowlist y auditoría), `validate-firewall-rules.sh`, `infra-verify.sh`.

## Comandos

| Comando | Qué hace |
| --- | --- |
| `/forja:init [--force]` | Bootstrap de un proyecto nuevo: preflight, esqueleto ejecutable, Gitflow, GitHub. |
| `/forja:deploy preview\|production` | Release por fases con scripts deterministas, gates humanos y backup off-site. |
| `/forja:rollback preview\|production` | Volver a una versión sana; el plano datos es aparte y human-confirmed. |
| `/forja:status` | Solo lectura: quién está en qué, PRs abiertos, cambios SDD activos, slices libres. |
| `/forja:doctor` | Diagnóstico de herramientas y conformidad del proyecto, con remediaciones. |

## Skills

- **`forja:doctrina`** — protocolo de consulta de la wiki: MANIFIESTO → receta por tarea → docs exactos en orden.
- **`forja:spec-doc-interviewer`** — entrevista que construye `software_requirements/` (PRD, glosario, requisitos, reglas, dominio) como insumo de gentle-ai. Decí "entrevistame".

## Loop de desarrollo del plugin

```bash
claude --plugin-dir .            # sesión con el plugin local montado
/reload-plugins                  # recargar tras editar comandos/skills/hooks
claude plugin validate . --strict  # gate de estructura (corre también en CI)
```

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
templates/        esqueleto de proyecto que instancia /forja:init (fase 3)
wiki/             la doctrina: 28 docs en 4 tiers + MANIFIESTO derivado
```

## Editar la doctrina

1. Editá los docs en `wiki/` (frontmatter incluido) en una rama.
2. Regenerá el índice: `node wiki/_meta/validate-graph.mjs --write` — el `MANIFIESTO.md` es un artefacto derivado, **nunca se edita a mano**.
3. Abrí un PR a este repo. El gate `validate-graph.mjs --check` corre en CI y falla si el MANIFIESTO quedó desincronizado.
