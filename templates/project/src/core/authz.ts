// Authorization (doctrine: wiki arquitectura/03 §6): a single mechanism,
// permission scopes with DENY-BY-DEFAULT. Pure module, no I/O.
//
// The guard is APPLIED in each feature's use-cases.ts, before any state
// change. The Actor is ALWAYS derived server-side from a verified session —
// never from body/headers/params. Authentication (Better Auth) arrives with
// the first feature that needs it; this seam does not change when it does:
// a machine actor is just an Actor with its own permission set.
import { PermissionDeniedError } from "@/core/errors";

export interface Actor {
  readonly id: string;
  readonly permissions: readonly string[];
}

// null = unauthenticated; absent permission = denied. Both fall to the same
// deny-by-default outcome: permission_denied (403 at the edge).
export function requirePermission(
  actor: Actor | null,
  permission: string,
): void {
  if (!actor?.permissions.includes(permission)) {
    throw new PermissionDeniedError(permission);
  }
}
