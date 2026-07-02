// Typed configuration (doctrine: wiki arquitectura/03 §10 + ops/07).
// The contract: THE SECRET NAME IS THE FIELD NAME. In prod each field is a
// file /run/secrets/<field> (Docker secret); in local dev the fallback is the
// UPPERCASED env var (loaded from .env by Next). No mapping table exists —
// the name is the contract. Fails fast at first access, naming every missing
// or malformed field.
import "server-only";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";

const DEFAULT_SECRETS_DIR = "/run/secrets";

// One field per secret. A new secret = a new field here + its Docker secret
// (and a build placeholder in the Dockerfile builder stage).
const ConfigSchema = z.object({
  db_url: z.string().min(1),
  session_secret: z.string().min(32),
  app_base_url: z.url(),
});

export type Config = z.infer<typeof ConfigSchema>;

function readSource(field: string, secretsDir: string): string | undefined {
  const secretFile = join(secretsDir, field);
  if (existsSync(secretFile)) return readFileSync(secretFile, "utf8").trim();
  return process.env[field.toUpperCase()];
}

let cached: Config | undefined;

export function getConfig(): Config {
  if (cached) return cached;
  // SECRETS_DIR is overridable so tests can point at a fixture directory.
  const secretsDir = process.env.SECRETS_DIR ?? DEFAULT_SECRETS_DIR;
  const raw = Object.fromEntries(
    Object.keys(ConfigSchema.shape).map((field) => [
      field,
      readSource(field, secretsDir),
    ]),
  );
  const parsed = ConfigSchema.safeParse(raw);
  if (!parsed.success) {
    const fields = [
      ...new Set(parsed.error.issues.map((issue) => issue.path.join("."))),
    ].join(", ");
    throw new Error(
      `invalid configuration - missing or malformed fields: ${fields} ` +
        `(each field is a file in ${secretsDir} or an UPPERCASED env var)`,
    );
  }
  cached = parsed.data;
  return cached;
}
