// getConfig(): the secret-name = field-name contract, exercised against a
// fixture SECRETS_DIR. The module caches a singleton, so each test reloads it
// with vi.resetModules() + a dynamic import.
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const FIXTURE = {
  db_url: "postgres://app:app@localhost:5432/app",
  session_secret: "0123456789abcdef0123456789abcdef",
  app_base_url: "http://localhost:3000",
};

const ENV_FALLBACKS = ["DB_URL", "SESSION_SECRET", "APP_BASE_URL"];

function writeSecrets(dir: string, fields: Record<string, string>): void {
  for (const [field, value] of Object.entries(fields)) {
    // Trailing newline on purpose: the loader must trim file contents.
    writeFileSync(join(dir, field), `${value}\n`, "utf8");
  }
}

async function loadGetConfig() {
  vi.resetModules();
  const { getConfig } = await import("@/core/config");
  return getConfig;
}

describe("getConfig", () => {
  let secretsDir: string;
  const savedEnv = new Map<string, string | undefined>();

  beforeEach(() => {
    secretsDir = mkdtempSync(join(tmpdir(), "forja-secrets-"));
    savedEnv.set("SECRETS_DIR", process.env.SECRETS_DIR);
    process.env.SECRETS_DIR = secretsDir;
    // Env fallbacks must not leak into the assertions.
    for (const key of ENV_FALLBACKS) {
      savedEnv.set(key, process.env[key]);
      delete process.env[key];
    }
  });

  afterEach(() => {
    for (const [key, value] of savedEnv) {
      if (value === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
    savedEnv.clear();
  });

  it("parses when every secret file is present (and trims file contents)", async () => {
    writeSecrets(secretsDir, FIXTURE);
    const getConfig = await loadGetConfig();
    const config = getConfig();
    expect(config).toEqual(FIXTURE);
  });

  it("fails fast naming the missing field", async () => {
    writeSecrets(secretsDir, {
      db_url: FIXTURE.db_url,
      app_base_url: FIXTURE.app_base_url,
    });
    const getConfig = await loadGetConfig();
    expect(() => getConfig()).toThrowError(/session_secret/);
  });

  it("falls back to the UPPERCASED env var when the file is absent", async () => {
    writeSecrets(secretsDir, {
      db_url: FIXTURE.db_url,
      session_secret: FIXTURE.session_secret,
    });
    process.env.APP_BASE_URL = FIXTURE.app_base_url;
    const getConfig = await loadGetConfig();
    expect(getConfig().app_base_url).toBe(FIXTURE.app_base_url);
  });

  it("caches the parsed config (singleton)", async () => {
    writeSecrets(secretsDir, FIXTURE);
    const getConfig = await loadGetConfig();
    expect(getConfig()).toBe(getConfig());
  });
});
