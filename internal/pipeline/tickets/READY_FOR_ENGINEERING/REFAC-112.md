---
id: REFAC-112
type: refactor
severity: low
title: Factor sol up's shared plan preparation out of run_dry_run and run_apply
source: operator code-review notes (2026-09-25, sol-logan-review), cli/bin/cmd_up.ml
---

**Depends on:** None.

## The problem

`cmd_up.run_dry_run` (`cli/bin/cmd_up.ml:203`) and `run_apply` (`:367`) open with
the same three steps, in the same order:

```ocaml
print_header ~workspace ~sha ~dry_run:...;
let plan = build_plan ~requested_scope ~workspace ~sha ~services in
record_plan run_log plan;
```

They differ only in the `dry_run` flag, and the two copies can drift. For example,
a new step added to one mode's preamble and forgotten in the other.

## Remediation

One `prepare_plan ~run_log ~dry_run ~requested_scope ~workspace ~sha ~services`
that does the three steps and returns the plan. Both modes call it. If REFAC-111
lands first, it takes the `selection`/`workspace` values instead of the separate
arguments.

## Acceptance criteria

- [ ] `print_header`, `build_plan` and `record_plan` each have one call site in
      `cmd_up.ml`, inside `prepare_plan`.
- [ ] `sol up --dry-run` output unchanged (existing tests).
- [ ] Demo coverage: internal refactor. Say so in the notes.
