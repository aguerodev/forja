import { readFileSync } from "node:fs";
import { defineConfig } from "drizzle-kit";

// Same two-source contract as src/core/config.ts (doctrine: wiki ops/07):
// CI and local dev pass DATABASE_URL as an env var; the Swarm migration
// one-shot reads the mounted Docker secret. `drizzle-kit generate` needs no
// live connection, so a missing URL must never crash — it resolves lazily.
function resolveDbUrl(): string | undefined {
  if (process.env.DATABASE_URL) return process.env.DATABASE_URL;
  try {
    return readFileSync("/run/secrets/db_url", "utf-8").trim();
  } catch {
    return undefined;
  }
}

export default defineConfig({
  dialect: "postgresql",
  // Vertical slices own their tables; migrations are generated centrally.
  schema: "./src/features/**/table.ts",
  out: "./src/core/db/migrations",
  dbCredentials: { url: resolveDbUrl() ?? "" },
});
