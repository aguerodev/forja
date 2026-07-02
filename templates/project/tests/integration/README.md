# Integration tests

Testcontainers suites live here (real Postgres, session-scoped container),
mirroring `src/`: `tests/integration/features/<feature>/repository.test.ts`.
Run with `pnpm test:integration` (requires a running Docker daemon). Not part
of `pnpm run check` — it is its own blocking PR job.
