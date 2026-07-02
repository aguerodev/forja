// Liveness/readiness endpoint (doctrine: wiki ops/02). It NEVER throws:
// db down -> 503 with a body, so the Swarm healthcheck and deploy
// verification always get an answer they can parse.
// - buildSha comes from the RUNTIME env: the Docker runner stage sets
//   ENV BUILD_SHA=<git sha>; the dev server reports "dev". Deploy and
//   rollback verify the served version against this field.
// - db: SELECT 1 through the pool with a 1s bound.
import { ping } from "@/core/db/client";

export const dynamic = "force-dynamic";

export async function GET(): Promise<Response> {
  const dbOk = await ping();
  return Response.json(
    {
      status: dbOk ? "ok" : "degraded",
      buildSha: process.env.BUILD_SHA ?? "dev",
      db: dbOk ? "ok" : "down",
    },
    {
      status: dbOk ? 200 : 503,
      headers: { "cache-control": "no-store" },
    },
  );
}
