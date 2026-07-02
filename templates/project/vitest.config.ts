import path from "node:path";
import { defineConfig } from "vitest/config";

// Two Vitest projects (doctrine: wiki arquitectura/07):
// - unit: what `pnpm run check` runs. Domain + use cases, no I/O, milliseconds.
// - integration: testcontainers suites against a real Postgres. Runs as its
//   own PR job (`pnpm test:integration`), never inside the fast loop.
// Coverage (v8) is a METRIC, not a merge gate.
const alias = {
  "@": path.resolve(import.meta.dirname, "src"),
  // The real `server-only` package throws outside a React Server environment;
  // tests exercise server modules directly, so it resolves to an empty stub.
  "server-only": path.resolve(
    import.meta.dirname,
    "tests/helpers/server-only-stub.ts",
  ),
};

export default defineConfig({
  test: {
    coverage: {
      provider: "v8",
      include: ["src/**"],
    },
    projects: [
      {
        test: {
          name: "unit",
          environment: "node",
          include: ["tests/unit/**/*.test.ts"],
        },
        resolve: { alias },
      },
      {
        test: {
          name: "integration",
          environment: "node",
          include: ["tests/integration/**/*.test.ts"],
        },
        resolve: { alias },
      },
    ],
  },
});
