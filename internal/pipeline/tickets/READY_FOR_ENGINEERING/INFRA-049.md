---
id: INFRA-049
type: refactor
severity: medium
title: Decide whether a target-level `omit` should exempt a unit from the profile preflight
source: audit finding FND-0012 — two live observations during AWS Run 8
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0012-omit-does-not-exempt-from-profile-preflight.md`

## The defect as observed

A target that omits a service does not exempt it from the profile preflight. Run
8's target omits the workspace's two TypeScript services; the production-profile
preflight still reports:

```text
- qualified version set is not established [application]: service "order_svc"
  declares language typescript, which production-single-region/v1 does not qualify
- immutable artifact identity is not established [application]: every workload
  must deploy an immutable reference; ...
```

The second error follows from the first: the omitted units are still in scope, and
they have no `--image-ref`. So `sol deploy` of the workspace's OCaml services
without `--scope` cannot pass the preflight. Only `--scope` narrows the view.

`omit` is a real key, and `sol/dev/aws/us-east-1.yml` uses it the same way, which
is what makes the behaviour surprising rather than merely undocumented.

## First: establish the intent

This ticket must not change behaviour before that is settled, because the two
readings imply opposite fixes:

- **If `omit` is meant to remove a unit from the target's declared set**, the
  preflight should not report it, and the fix is in how the preflight derives the
  application from the resolved config rather than the workspace manifest.
- **If `omit` only removes a unit from what gets *deployed*** — and the
  preflight deliberately reports the workspace's declared languages, as
  `sol.yml`'s own comment suggests ("the honest state until the TS parity
  triggers fire", DEC-026 §2) — then the defect is that `omit` reads as if it
  exempts, and the fix is documentation plus an explicit statement that the
  production profile is deployed `--scope`-ed.

Record the answer as a `DEC` if it is a contract choice, then implement.

## Acceptance criteria

1. The intended semantics of `omit` with respect to the profile preflight are
   stated in one place, and the qualification procedure says whether a run is
   expected to deploy `--scope`-ed or whole-workspace.
2. A target that omits a unit and one that does not behave distinguishably and
   explainably in the preflight, and a test pins whichever behaviour is chosen.
3. If the outcome is "the production profile is always deployed `--scope`-ed",
   the pluto workspace's `sol.yml` comment and the AWS matrix's Run 8 commands
   say so, since that is the invocation every run must use.

## Out of scope

The TypeScript parity itself (DEC-026 §2) — this is about what `omit` means, not
about qualifying the TS demo pair.
