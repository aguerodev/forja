# {{PROJECT_NAME}}

Bootstrapped by **forja** (the agency's Claude Code plugin). The engineering
doctrine that governs this repo lives in the plugin — start with `CLAUDE.md`
and the `forja:doctrina` skill; do not guess conventions.

## Commands

The project contract lives in `.forja.json` — the plugin commands, hooks and
release scripts read it. The load-bearing commands:

| Command           | What it does                                              |
| ----------------- | --------------------------------------------------------- |
| `{{CMD_INSTALL}}` | Install dependencies                                      |
| `{{CMD_CHECK}}`   | ALL merge gates, local = CI (lint, types, tests, …)       |
| `{{CMD_TEST}}`    | Unit tests (no I/O; also part of the check gate)          |
| `{{CMD_VERSION}}` | Print the project version (release tagging reads it)      |

## Getting started

1. Install the project's runtime toolchain.
2. Run `{{CMD_INSTALL}}`.
3. Copy `env.example` to `.env` (gitignored) and fill in the dev values.
4. `{{CMD_CHECK}}` must be green before any PR.

## Notes

- Architecture: hexagonal core + vertical slices; the project's dependency
  linter enforces the boundaries.
- Deploy and operations run through the plugin commands: `/forja:deploy`,
  `/forja:rollback`, `/forja:status`, `/forja:doctor`.
