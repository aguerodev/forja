// Structured JSON logging (doctrine: wiki arquitectura/03 §12).
// `redact` is the SAFETY NET, not the rule. The rule: never pass raw domain
// entities or Drizzle rows to the logger — log projected fields (opaque id,
// error code, requestId). Users are identified by opaque id, never by email.
import pino from "pino";

export const logger = pino({
  level: process.env.LOG_LEVEL ?? "info",
  redact: {
    paths: [
      "password",
      "*.password",
      "*.token",
      "*.secret",
      "*.email",
      "req.headers.authorization",
      "req.headers.cookie",
    ],
    censor: "[REDACTED]",
  },
});
