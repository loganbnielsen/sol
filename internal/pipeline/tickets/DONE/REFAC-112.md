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

## Completion notes

Premise checked 2026-09-25 on `origin/main` (`85731f78`): `run_dry_run` and `run_apply` in `cli/bin/cmd_up.ml` each called `print_header`, `build_plan` and `record_plan` in turn.

- `prepare_plan ~run_log ~dry_run ~requested_scope ~workspace ~sha ~services` does the three steps and returns the plan. `grep -n 'print_header\|build_plan \|record_plan run_log' cli/bin/cmd_up.ml` shows the three definitions plus one call each, all inside `prepare_plan`.
- One ordering change, deliberate: `run_apply` used to run `check_consumer_group_changes` *between* building and recording the plan, and now it runs right after `prepare_plan`. So an apply refused for an unconfirmed consumer-group change now leaves its plan in the run log's `plan` phase. It used to leave nothing, which is the less useful record of what was refused. Nothing reaches the cluster before the check either way.
- REFAC-111 had not landed, so this takes the existing separate arguments. REFAC-111 will pass its `selection`/`workspace` values through the same function.
- Verification: `dune build`, `dune test cli/ --force` (58 suites, 0 failures), `internal/ci/check_ocamlformat.sh --all` clean.
- Demo/example: not applicable (internal refactor; `sol up --dry-run` output unchanged).
- Language parity (DEC-022): no impact.
