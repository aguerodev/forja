// The closed union of domain error codes and its ONLY HTTP translation.
// Exhaustiveness itself is a COMPILE-TIME guard: toHttpResponse ends in
// `assertNever(error.code)`, so adding a code to DOMAIN_ERROR_CODES without a
// case stops tsc — no runtime test can reach that branch without defeating
// the types. What runs here: every code maps to its pinned status.
import { describe, expect, it } from "vitest";
import {
  ConflictError,
  DOMAIN_ERROR_CODES,
  type DomainError,
  FeatureDisabledError,
  isDomainError,
  NotFoundError,
  PermissionDeniedError,
  RateLimitedError,
  UpstreamTimeoutError,
  UpstreamUnavailableError,
} from "@/core/errors";
import { toHttpResponse } from "@/core/http/errors";

const CASES: ReadonlyArray<{
  error: DomainError;
  code: string;
  status: number;
}> = [
  { error: new NotFoundError("missing"), code: "not_found", status: 404 },
  { error: new ConflictError("stale write"), code: "conflict", status: 409 },
  {
    error: new PermissionDeniedError("counters:increment"),
    code: "permission_denied",
    status: 403,
  },
  {
    error: new UpstreamUnavailableError("provider down"),
    code: "upstream_unavailable",
    status: 502,
  },
  {
    error: new UpstreamTimeoutError("provider slow"),
    code: "upstream_timeout",
    status: 504,
  },
  {
    error: new RateLimitedError("quota exhausted", 30),
    code: "rate_limited",
    status: 429,
  },
  {
    error: new FeatureDisabledError("kill-switch on"),
    code: "feature_disabled",
    status: 503,
  },
];

describe("DomainError closed union", () => {
  it("has a concrete error class for every declared code", () => {
    expect(new Set(CASES.map((entry) => entry.error.code))).toEqual(
      new Set(DOMAIN_ERROR_CODES),
    );
  });

  it("isDomainError narrows domain errors and rejects the rest", () => {
    expect(isDomainError(new NotFoundError("nope"))).toBe(true);
    expect(isDomainError(new Error("plain"))).toBe(false);
    expect(isDomainError(undefined)).toBe(false);
  });
});

describe("toHttpResponse (single translation point)", () => {
  it.each(CASES)("maps $code to HTTP $status", async ({
    error,
    code,
    status,
  }) => {
    const response = toHttpResponse(error);
    expect(response.status).toBe(status);
    const body = await response.json();
    expect(body.code).toBe(code);
    expect(typeof body.message).toBe("string");
  });

  it("propagates Retry-After for rate_limited from structured data", async () => {
    const response = toHttpResponse(new RateLimitedError("quota", 30));
    expect(response.headers.get("retry-after")).toBe("30");
    const body = await response.json();
    expect(body.params).toEqual({ retryAfter: 30 });
  });
});
