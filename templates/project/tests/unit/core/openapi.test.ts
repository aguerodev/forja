// The OpenAPI registration gates (doctrine: wiki arquitectura/07): the
// document assembles as 3.1, carries the shared ErrorBody component, and a
// duplicate method+path registration THROWS instead of silently corrupting
// the contract. Registry state is module-global; paths here are unique.
import { describe, expect, it } from "vitest";
import { buildOpenApiDocument, registerPath } from "@/core/http/openapi";

describe("central OpenAPI registry", () => {
  it("assembles an OpenAPI 3.1 document with registered paths and ErrorBody", () => {
    registerPath({
      method: "get",
      path: "/api/demo",
      responses: { 200: { description: "OK" } },
    });

    const document = buildOpenApiDocument();
    expect(document.openapi).toBe("3.1.0");
    expect(document.paths).toHaveProperty("/api/demo");
    expect(document.components?.schemas).toHaveProperty("ErrorBody");
  });

  it("throws on a duplicate method+path registration (collision gate)", () => {
    const operation = {
      method: "post",
      path: "/api/demo-duplicate",
      responses: { 201: { description: "created" } },
    } as const;

    registerPath(operation);
    expect(() => registerPath(operation)).toThrowError(/duplicate/i);
  });

  it("keeps distinct methods on the same path registrable", () => {
    registerPath({
      method: "get",
      path: "/api/demo-methods",
      responses: { 200: { description: "OK" } },
    });
    expect(() =>
      registerPath({
        method: "delete",
        path: "/api/demo-methods",
        responses: { 204: { description: "deleted" } },
      }),
    ).not.toThrow();
  });
});
