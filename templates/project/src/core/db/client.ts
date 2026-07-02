// Database client (doctrine: wiki arquitectura/02): lazy pg Pool singleton +
// drizzle handle. server-only: if a client-component import chain ever
// reaches this module, the build falls before the pool leaks to the browser.
// The pool is created on FIRST USE (never at import time) so that importing
// this module — e.g. from the health route — cannot crash a process whose
// secrets are not mounted yet.
import "server-only";
import { drizzle } from "drizzle-orm/node-postgres";
import { Pool } from "pg";
import { getConfig } from "@/core/config";

let pool: Pool | undefined;
let db: ReturnType<typeof drizzle> | undefined;

export function getPool(): Pool {
  if (!pool) {
    pool = new Pool({ connectionString: getConfig().db_url });
  }
  return pool;
}

// Drizzle over the shared pool: what feature repositories consume.
export function getDb(): ReturnType<typeof drizzle> {
  if (!db) {
    db = drizzle(getPool());
  }
  return db;
}

function pingTimeout(ms: number): Promise<never> {
  return new Promise((_, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`db ping timed out after ${ms}ms`)),
      ms,
    );
    timer.unref();
  });
}

// SELECT 1 with a 1s bound. NEVER throws: the health route translates
// false into a 503 body, it does not crash.
export async function ping(): Promise<boolean> {
  try {
    const probe = getPool().query("SELECT 1");
    // The probe may still reject after losing the race; keep it handled.
    probe.catch(() => undefined);
    await Promise.race([probe, pingTimeout(1_000)]);
    return true;
  } catch {
    return false;
  }
}
