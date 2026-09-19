---
id: INFRA-041
type: bug
severity: medium
title: DEC-033's retention never reaches the destroy, so a disposable target still retains
source: HARDEN Run 6 / Attempt 6 — destroy_retention: none was ignored and the
  operator deleted the snapshot by hand, which is what DEC-033 existed to remove
---

**Related:** DEC-033 (the feature this completes), ADR 0004 (retention semantics),
HARDEN-002 (the Run 5 experience this was meant to fix),
`~/.sol/harden-run6-attempt6/09-destroy.log`.

## The finding

Attempt 6's target declared `destroy_retention: none` — the disposable case DEC-033
added — and the destroy took a final snapshot anyway:

```text
prepare: disabling RDS deletion protection, final snapshot sol-qual10-…-final-…...
```

No `retention:` line was printed at all, and the independent verification found one
manual snapshot remaining. The operator deleted it by hand, so the run ended
cost-clean **only because of a manual step** — exactly the deviation DEC-033 was
written to eliminate (and the same shape as INFRA-037's stranded target: a
cost-safety property that only a human enforces).

Two defects, both verifiable from the tree:

1. **The report call never landed.** `retention_report` does not appear anywhere in
   `cli/sol/bin/cmd_cloud_tf.ml`. A string replacement was applied without checking
   it matched, so the report was never wired — and nothing failed, because there
   was no test asserting the destroy prints it.
2. **The field does not reach the destroy.** The destroy still resolved
   `Retain_final_snapshot` for a target that says `none`, so `target_cfg` at the
   resolution point did not carry `Some "none"`. The exact path is not yet
   established and must be, rather than guessed at.

## Why the tests did not catch it

This is the part worth fixing as carefully as the code. The DEC-033 tests cover
`policy_vars` and `retention_report` — **the model** — and the lifecycle harness
exercises only the default retention. Nothing:

- parsed a target file containing `destroy_retention` and asserted the field
  survives to the point of use (the config layer, not the model);
- asserted that the destroy path *honours* non-default retention end to end;
- asserted that the destroy reports what it kept, which is half of what DEC-033
  promises an operator.

A feature whose selection is never exercised end to end is not landed, however
well its model is tested.

## Acceptance criteria

- The destroy resolves retention from the target's field; a parsed target carrying
  `destroy_retention: none` demonstrably reaches the Destroy policy.
- The destroy prints its retention report, including the identifier and how the
  snapshot is eventually removed.
- Tests cover the three layers that were missing: target parsing carries the field;
  the destroy path honours both modes (the harness gains a `none` scenario rather
  than only the default); and the report is asserted, not assumed.
- The Run 6 procedure's cost-clean verification is reachable without a manual
  deletion.

**Demo/example coverage:** The qualification target already carries the field.

**TypeScript parity:** No language-parity impact.
