---
id: CODEX_STYLE_AUDIT-085
type: bug
severity: high
title: "Refuse deployment when the previous contract cannot be observed"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Refuse deployment when the previous contract cannot be observed

**Depends on:** None.

**Principles:** 1, 6, 15, 21, 22, 29, 31–33, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/bin/cmd_up.ml:180`: `observed_contract` maps current-pointer read errors and pointed-release errors to `[]`.
- `cli/lib/deploy/sol_cli_deploy_run.ml:245`: `previous_contract` repeats that policy; `observe_contract` supplies the empty baseline to plan validation.
- `cli/lib/deploy/sol_cli_deployment_plan.ml:633`: compatibility rules reject partition decreases, changed record keys, and topic renames. `contract_changes_between` treats every desired subject as Added when the observation is empty.

## Mechanism and impact

An unreadable pointer, malformed release, or dangling pointer becomes indistinguishable from a genuine first deployment. The plan loses the baseline needed to identify incompatible changes. Later registry reconciliation may reject some changes, but does not restore the missing plan evidence or guarantee detection of changed record keys. This is a fail-open observation boundary, not merely duplicate code.

## Remediation

Introduce one Result-returning deployed-contract reader used by local and cloud deployment. Only an explicitly absent current pointer yields an empty previous contract. A failed pointer read or a failed read of the named record must return a contextual error before deployment mutation.

## Acceptance criteria

- Permission denial, malformed stored record, and dangling current pointer prevent deployment mutation and preserve the originating error.
- A genuine first deployment remains valid.
- Partition decrease, key change, and topic rename remain refused against a known baseline.
- Exercise both command paths through fake Kubernetes reads, including proof that no apply follows an unobservable baseline.

- Demo/example: update a runnable contract-change example or tutorial with the refusal and recovery behavior.
- Language parity: the CLI gate applies identically to OCaml and TypeScript declarations; record that shared capability verdict.

## Existing work and scope

BUG-200 is completed multi-language registration work, not an owner for this failure. No open ticket was found for previous-contract error suppression. Consolidate both callers under this one observation policy.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
