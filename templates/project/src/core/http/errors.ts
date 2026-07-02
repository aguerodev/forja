// DomainError -> HTTP response: the ONLY translation point in the whole app
// (doctrine: wiki arquitectura/03 §7). The switch is exhaustive over the
// closed union DomainErrorCode — not an instanceof chain: if a code is added
// to DOMAIN_ERROR_CODES and its case is missing here, `error.code` stops
// being `never` in the default branch and the build falls. The guardrail is
// the type, not the discipline of remembering the case.
import {
  type DomainError,
  type DomainErrorCode,
  RateLimitedError,
} from "@/core/errors";

function assertNever(value: never): never {
  throw new Error(`unhandled domain error code: ${String(value)}`);
}

// Typed error body: IS part of the OpenAPI contract (every 4xx/5xx response).
// `code` is the stable, semantic key; `params` carries structured data so the
// client interpolates its own text (i18n, retryAfter); `message` is a sanitized
// readable fallback — never internals, never PII.
export interface ErrorBody {
  code: DomainErrorCode;
  params?: Record<string, string | number>;
  message?: string;
}

function rateLimitParams(
  error: DomainError,
): Record<string, string | number> | undefined {
  if (
    error instanceof RateLimitedError &&
    error.retryAfterSeconds !== undefined
  ) {
    return { retryAfter: error.retryAfterSeconds };
  }
  return undefined;
}

function rateLimitHeaders(
  error: DomainError,
): Record<string, string> | undefined {
  if (
    error instanceof RateLimitedError &&
    error.retryAfterSeconds !== undefined
  ) {
    return { "Retry-After": String(error.retryAfterSeconds) };
  }
  return undefined;
}

export function toHttpResponse(error: DomainError): Response {
  const body: ErrorBody = { code: error.code, message: error.message };
  switch (error.code) {
    case "not_found":
      return Response.json(body, { status: 404 });
    case "conflict":
      return Response.json(body, { status: 409 });
    case "permission_denied":
      return Response.json(body, { status: 403 });
    case "upstream_unavailable":
      // Upstream did not answer or answered garbage. The NUMBER lives only
      // here: the domain code is semantic, this is transport.
      return Response.json(body, { status: 502 });
    case "feature_disabled":
      // Kill-switch: the resource exists but is not serving right now -> 503.
      // (It may map to 404 when the semantics are "does not exist for this
      // caller"; that is decided per resource.)
      return Response.json(body, { status: 503 });
    case "upstream_timeout":
      return Response.json(body, { status: 504 });
    case "rate_limited":
      // 429 propagates Retry-After from the error's structured data.
      return Response.json(
        { ...body, params: rateLimitParams(error) },
        { status: 429, headers: rateLimitHeaders(error) },
      );
    default:
      return assertNever(error.code);
  }
}
