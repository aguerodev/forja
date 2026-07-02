// Serves the OpenAPI 3.1 document assembled from the slices (doctrine: wiki
// arquitectura/07). This is exactly the artifact the contract gate
// (Schemathesis) consumes. Internal route: it does not register itself.
import { buildOpenApiDocument } from "@/core/http/openapi";

export function GET(): Response {
  return Response.json(buildOpenApiDocument());
}
