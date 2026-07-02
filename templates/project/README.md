# {{PROJECT_NAME}}

Bootstrapped by **forja** (the agency's Claude Code plugin). The engineering
doctrine that governs this repo lives in the plugin — start with `CLAUDE.md`
and the `forja:doctrina` skill; do not guess conventions.

## Commands

| Command                 | What it does                                               |
| ----------------------- | ---------------------------------------------------------- |
| `pnpm dev`              | Next.js dev server on `localhost:3000`                     |
| `pnpm run check`        | ALL merge gates, local = CI (lint, types, arch, tests, …)  |
| `pnpm run fix`          | Auto-format + lint fixes + Tailwind class order            |
| `pnpm test:unit`        | Unit project (no I/O; also part of `check`)                |
| `pnpm test:integration` | Integration project (testcontainers; needs Docker)         |
| `pnpm db:generate`      | Generate SQL migrations from `src/features/**/table.ts`    |
| `pnpm db:migrate`       | Apply migrations (`DATABASE_URL` or `/run/secrets/db_url`) |

## Getting started

1. `nvm use` (Node pinned in `.nvmrc`) and `corepack enable pnpm`.
2. `pnpm install`.
3. Copy `.env.example` to `.env` (gitignored) and fill in the dev values.
4. `pnpm run check` must be green before any PR.

## Notes

- Architecture: hexagonal core + vertical slices under `src/features/`;
  the six dependency-cruiser contracts enforce it (`depcruise src`).
- Auth is deliberately absent: **Better Auth arrives with the first feature
  that needs authentication** (dial escalation, not a day-one dependency).
- Deploy and operations run through the plugin commands: `/forja:deploy`,
  `/forja:rollback`, `/forja:status`, `/forja:doctor`.
