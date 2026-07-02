// The egress edge (doctrine: wiki arquitectura/03 §5): EVERY outbound call to
// a third party leaves through this client — the dependency-cruiser contract
// `egress-through-httpclient` forbids raw network primitives anywhere else.
// Two controls travel in the seam:
// - `timeoutMs` is a REQUIRED parameter of the signature (no runtime
//   default): if an adapter omits it, tsc breaks the build.
// - Failures are translated to semantic DomainErrors (upstream_timeout /
//   upstream_unavailable); no provider/network error escapes raw.
// Anti-SSRF destination validation is a dial escalation: it becomes mandatory
// the day a destination URL derives from user or third-party data. For
// config-constant destinations the SSRF surface is zero.
import "server-only";
import { UpstreamTimeoutError, UpstreamUnavailableError } from "@/core/errors";

export interface HttpRequest {
  readonly method: "GET" | "POST" | "PUT" | "DELETE";
  /** Resolved against the client's baseUrl. */
  readonly path: string;
  readonly body?: unknown;
  readonly headers?: Readonly<Record<string, string>>;
  /** REQUIRED — no runtime default. The concrete value comes from config. */
  readonly timeoutMs: number;
}

export interface HttpResponse {
  readonly status: number;
  readonly headers: Headers;
  readonly body: unknown;
}

export interface HttpClient {
  send(request: HttpRequest): Promise<HttpResponse>;
}

export function createHttpClient(baseUrl: string): HttpClient {
  return {
    async send(request: HttpRequest): Promise<HttpResponse> {
      const url = new URL(request.path, baseUrl);
      let response: Response;
      try {
        response = await fetch(url, {
          method: request.method,
          headers: {
            ...(request.body !== undefined
              ? { "content-type": "application/json" }
              : {}),
            ...request.headers,
          },
          body:
            request.body !== undefined
              ? JSON.stringify(request.body)
              : undefined,
          signal: AbortSignal.timeout(request.timeoutMs),
        });
      } catch (error) {
        if (error instanceof Error && error.name === "TimeoutError") {
          throw new UpstreamTimeoutError(
            `upstream did not answer within ${request.timeoutMs}ms`,
            { cause: error },
          );
        }
        throw new UpstreamUnavailableError(
          "upstream request failed before a response arrived",
          { cause: error },
        );
      }
      return {
        status: response.status,
        headers: response.headers,
        body: await parseBody(response),
      };
    },
  };
}

async function parseBody(response: Response): Promise<unknown> {
  const text = await response.text();
  const contentType = response.headers.get("content-type") ?? "";
  if (!contentType.includes("application/json") || text === "") return text;
  try {
    return JSON.parse(text);
  } catch (error) {
    // Upstream declared JSON and sent garbage: that is an upstream failure.
    throw new UpstreamUnavailableError("upstream answered malformed JSON", {
      cause: error,
    });
  }
}
