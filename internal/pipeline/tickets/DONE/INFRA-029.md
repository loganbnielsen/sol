---
id: INFRA-029
type: bug
severity: medium
title: Destruction is an abort edge — a failed or partially installed target must stay destructible
source: HARDEN-002 Run 5 preparation, 2026-09-18 — model/operation disagreement
  found while writing the lifecycle into the qualification specification
---

**Depends on:** None.

**Related:** ADR 0003 (invariant 6, added here), INFRA-028 (the phase model),
INFRA-023 (destroy preparation), HARDEN-002 (the qualification this gates).

## What this is

ADR 0003 invariant 5 says the transition relation admits *only* the edges in the
diagram. The diagram reaches `PreparingDestroy` from `Ready` alone, and the unit
test pins `PlatformInstalling -> PreparingDestroy` as **rejected**.

`sol cloud destroy` did not consult that relation at all. It asserted the phase
directly:

```ocaml
(* cli/sol/bin/cmd_cloud_tf.ml, destroy/--apply, before this ticket *)
let destroy_phase = Sol_cli_cloud_lifecycle.Preparing_destroy in
```

So the operation was legal from every state while the model said one of those
edges was illegal. Two consequences, one latent and one immediate:

- **Latent, and the dangerous one.** The obvious "fix" for a model/operation
  disagreement is to route the operation through the relation. Doing that here
  would make `sol cloud destroy` **refuse to tear down a partially installed
  target** — a run that failed midway (partial platform install, interrupted
  privileged update) would have no exit through Sol's public lifecycle but manual
  surgery on live cloud resources.
- **Immediate.** The relation was decorative on the destroy path, so nothing
  enforced it, and the destroy phase reported `PreparingDestroy` even when the
  substrate was absent — a phase that did not describe the target.

## Decision

The required invariant is: **a failed or partially installed target must always
remain destructible through Sol's public lifecycle; lifecycle enforcement must
never strand infrastructure.**

Destruction is therefore modelled as an **abort edge**, not a forward transition
(ADR 0003 invariant 6):

```ocaml
let destruction_available = function
  | Absent -> false
  | Cloud_bootstrap | Platform_installing | Ready | Platform_updating
  | Preparing_destroy | Destroying -> true
;;

let enter_destruction ~from =
  if destruction_available from then Preparing_destroy else Absent
;;
```

Why separate rather than "add the edges to `transition_allowed`": the forward
relation describes *progressive establishment*, and its value is that it says
exactly what the diagram says. Folding teardown into it would make the relation
mean "every legal move", and the rejection of `PlatformInstalling ->
PreparingDestroy` — which is still correct, for a forward move — would have to be
deleted to make room.

`enter_destruction` is total on purpose. Destroying an absent target yields
`Absent`, the post-destroy state, so destroy stays idempotent instead of becoming
an error.

## Remediation

- `cli/sol/lib/sol_cli_cloud_lifecycle.ml/.mli` — add `destruction_available` and
  `enter_destruction`; document `transition_allowed` as the *forward* relation.
- `cli/sol/bin/cmd_cloud_tf.ml` — the destroy path derives its phase from
  `enter_destruction` instead of asserting it, and reports the real phase
  (`Absent` when nothing exists).
- `docs/architecture/adr/0003-lifecycle-phases-authority-and-policy.md` — new
  invariant 6; invariant 5 restated as the *forward* relation; implementation and
  regression-coverage sections updated.
- `cli/sol/test/test_cloud_lifecycle.ml` — the abort edge admitted from every
  phase except `Absent`; destroying never lands in a Ready-policy phase; the
  forward relation still rejects the same edge, so the distinction is pinned
  rather than lost.
- `internal/ci/test_cloud_lifecycle_offline.sh` — a scenario that destroys a
  *partially installed* target (substrate present, platform never fully
  installed). A future implementation that routes destroy through the forward
  relation, or gates teardown on a probe that can fail, fails this scenario.

## Acceptance criteria

- The forward relation is unchanged: `PlatformInstalling -> PreparingDestroy`
  stays rejected, because a forward move is still a forward move.
- The abort edge admits every phase except `Absent`, so no partially built target
  is stranded.
- `sol cloud destroy` on a partially installed target succeeds and reports
  `PreparingDestroy`; the offline harness asserts it.
- Destroying an absent target remains a successful no-op and now reports the
  phase it is actually in.
- Nothing in the destroy path depends on an observation that can fail: the abort
  edge gives the same answer for `Ready` and `PlatformInstalling`, so a destroy
  decides only Absent-ness.
- No phase is persisted, and no second state database is introduced.

**Demo/example coverage:** Internal lifecycle enforcement. No runnable example
changes: `examples/pluto` and the tutorial do not exercise `sol cloud destroy`
against a partially installed production target, and inventing one would require
a live target. Stated as the exemption.

**TypeScript parity:** No language-parity impact — CLI lifecycle enforcement.
