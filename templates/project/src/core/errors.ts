// Domain error hierarchy (doctrine: wiki arquitectura/03 §7).
// PURE module: no framework, no I/O, no Zod. The closed union of codes is what
// gives the compiler exhaustiveness in toHttpResponse (src/core/http/errors.ts):
// the literal list lives ONCE, as an `as const` array, and both the type and
// the OpenAPI ErrorBody enum derive from it.
//
// Feature errors extend one of these base classes and REUSE its code
// (e.g. `class CounterPersistenceError extends ConflictError {}`). If a
// feature truly needs a new code, it is added here — and the exhaustive
// switch in toHttpResponse stops compiling until the case is handled.
// That is the point.

export const DOMAIN_ERROR_CODES = [
  // Own domain.
  "not_found",
  "conflict",
  "permission_denied",
  // Upstream dependency failures: SEMANTIC codes — no HTTP status is baked
  // in. The egress adapter translates provider failures into one of these;
  // the code -> status mapping lives ONLY in src/core/http/errors.ts.
  "upstream_unavailable", // upstream did not answer, or answered garbage
  "upstream_timeout", // upstream did not answer in time
  "rate_limited", // quota exhausted (ours or the upstream's)
  // Kill-switch: the capability is turned off by a flag for this caller.
  "feature_disabled",
] as const;

export type DomainErrorCode = (typeof DOMAIN_ERROR_CODES)[number];

export abstract class DomainError extends Error {
  abstract readonly code: DomainErrorCode;

  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = new.target.name;
  }
}

export class NotFoundError extends DomainError {
  readonly code = "not_found";
}

export class ConflictError extends DomainError {
  readonly code = "conflict";
}

export class PermissionDeniedError extends DomainError {
  readonly code = "permission_denied";

  constructor(permission: string) {
    super(`missing required permission: ${permission}`);
  }
}

export class UpstreamUnavailableError extends DomainError {
  readonly code = "upstream_unavailable";
}

export class UpstreamTimeoutError extends DomainError {
  readonly code = "upstream_timeout";
}

export class RateLimitedError extends DomainError {
  readonly code = "rate_limited";

  // Structured data, not a pre-baked string: `retryAfterSeconds` travels in
  // the error body `params` so clients (and the Retry-After header) can use it.
  constructor(
    message: string,
    readonly retryAfterSeconds?: number,
  ) {
    super(message);
  }
}

export class FeatureDisabledError extends DomainError {
  readonly code = "feature_disabled";
}

export function isDomainError(value: unknown): value is DomainError {
  return value instanceof DomainError;
}
