---
id: REFAC-052
type: audit-finding
severity: medium
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-052/remove-dead-follow
worktree: ../sun-REFAC-052-remove-dead-follow
---

Remove dead `_follow` parameter and fix contradictory bool flags in `cmd_logs.run`

**Depends on:** None.

**Description:**

`cli/sun/bin/cmd_logs.ml:63`:

```ocaml
let run (service_arg : string) (_follow : bool) (no_follow : bool) (tail : int) ...
```

Two issues:

1. `_follow : bool` is a dead parameter — it is never read. Its prefixed underscore signals the compiler warning was suppressed rather than the parameter removed. The actual follow behaviour is derived from `no_follow` on the next line: `let follow = not no_follow`.

2. The resulting `run` function takes two consecutive boolean arguments with inverted semantics from the same concept. Any caller must know that the second bool (`no_follow`) is the one that actually matters, and pass an arbitrary value for the first.

**Remediation:**

1. Delete `_follow` from the `run` signature.
2. Update the Cmdliner term wiring in the same file to not pass the `_follow` value.
3. Rename the remaining parameter to `no_follow` (keeping current semantics) or invert it to `follow` and remove the negation — whichever matches the Cmdliner flag that is exposed to users.

## Review — automated checks passed
Dead _follow parameter removed, follow_term wires both flags correctly, run body uses follow directly, build clean
