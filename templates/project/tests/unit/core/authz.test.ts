// requirePermission: the NEGATIVE authorization pattern (doctrine: wiki
// arquitectura/04). Every permission a feature requires must have its
// negative test — denial is asserted, never assumed.
import { describe, expect, it } from "vitest";
import { type Actor, requirePermission } from "@/core/authz";
import { PermissionDeniedError } from "@/core/errors";

const PERMISSION = "counters:increment";

function actorWith(permissions: readonly string[]): Actor {
  return { id: "actor-1", permissions };
}

function capture(fn: () => void): unknown {
  try {
    fn();
    return undefined;
  } catch (error) {
    return error;
  }
}

describe("requirePermission (deny-by-default)", () => {
  it("allows an actor holding the exact permission", () => {
    expect(() =>
      requirePermission(actorWith([PERMISSION, "other:read"]), PERMISSION),
    ).not.toThrow();
  });

  it.each([
    {
      name: "an actor without the permission",
      actor: actorWith(["other:read"]),
    },
    { name: "an actor with no permissions at all", actor: actorWith([]) },
    { name: "an unauthenticated caller (null actor)", actor: null },
  ])("denies $name", ({ actor }) => {
    const failure = capture(() => requirePermission(actor, PERMISSION));
    expect(failure).toBeInstanceOf(PermissionDeniedError);
    if (failure instanceof PermissionDeniedError) {
      expect(failure.code).toBe("permission_denied");
      expect(failure.message).toContain(PERMISSION);
    }
  });
});
