// Central OpenAPI registry (doctrine: wiki arquitectura/07). The HTTP
// contract is ASSEMBLED from the slices, never written by hand: every public
// route.ts registers its operations here with its own Zod schemas, and the
// aggregate is served as a single OpenAPI 3.1 document — the exact artifact
// Schemathesis fuzzes. Server Actions are internal RPC and never register.
import {
  extendZodWithOpenApi,
  OpenAPIRegistry,
  OpenApiGeneratorV31,
  type RouteConfig,
} from "@asteasolutions/zod-to-openapi";
import { z } from "zod";
import { DOMAIN_ERROR_CODES } from "@/core/errors";

extendZodWithOpenApi(z);

export const registry = new OpenAPIRegistry();

// The typed error body is part of the contract: every 4xx/5xx response uses
// it. The closed union is REUSED from core/errors — one list of literals.
export const ErrorBody = registry.register(
  "ErrorBody",
  z.object({
    code: z.enum(DOMAIN_ERROR_CODES),
    params: z.record(z.string(), z.union([z.string(), z.number()])).optional(),
    message: z.string().optional(),
  }),
);

const registeredOperations = new Set<string>();

// Every route.ts registers through this helper. A silent double registration
// of the same method+path corrupts the document; here it throws instead —
// the collision gate runs in the unit suite, so it fails the build.
export function registerPath(config: RouteConfig): void {
  const operation = `${config.method} ${config.path}`;
  if (registeredOperations.has(operation)) {
    throw new Error(`duplicate OpenAPI registration: ${operation}`);
  }
  registeredOperations.add(operation);
  registry.registerPath(config);
}

// Aggregates every registered operation and emits the OpenAPI 3.1 document.
export function buildOpenApiDocument() {
  const generator = new OpenApiGeneratorV31(registry.definitions);
  return generator.generateDocument({
    openapi: "3.1.0",
    info: { title: "API", version: "1.0.0" },
  });
}
