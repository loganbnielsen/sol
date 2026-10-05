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

## Completion notes (2026-10-05)

**Premise re-verified at pickup** on `origin/main` `7588e7cb`: `cli/bin/cmd_up.ml`
`observed_contract` and `cli/lib/deploy/sol_cli_deploy_run.ml` `previous_contract` still mapped a
failed pointer read and a failed read of the named record to `[]`, making an unreadable pointer,
malformed release or dangling pointer indistinguishable from a genuine first deployment.

**Fix.** `Sol_cli_release_store.deployed_contract` is now the single Result-returning
deployed-contract reader. An explicitly absent current pointer (`Ok None`) yields the empty
baseline; a failed `current` read or a failed `get` of the named release returns a contextual
`Error`. `cmd_up.observed_contract` and `sol_cli_deploy_run.previous_contract` both call it, and
both observe the contract during plan preparation, before any apply, so an unobservable baseline
now refuses before deployment mutation. In `sol deploy`'s apply path the observation runs after
`check_substrate_prerequisite`, so an unreachable cluster still reports the environment stage and
the `sol cloud apply <target>` guidance rather than an incidental pointer-read failure; a reachable
cluster with an unreadable pointer refuses before apply.

**Tests.** `cli/test/inline/test_release_contract.ml` drives the reader through a fake `kubectl`:
NotFound pointer yields `Ok []`; a Forbidden pointer returns `Error` retaining "Forbidden"; a
dangling pointer (pointer readable, release read Forbidden) returns `Error` naming the release id;
a malformed stored record returns `Error`. Existing `test_deployment_plan.ml` coverage still pins
partition-decrease, key-change and topic-rename refusal against a known baseline.

**Demo/example.** `docs/architecture/devops-pipeline.md` now documents the unobservable-baseline
refusal and recovery alongside the contract-change refusal it already described. No application
author writes anything differently, so no example code changed.

**Language parity (DEC-022).** No divergence: the CLI gate is shared and applies identically to
OCaml and TypeScript declarations; recorded as an already-equivalent capability.

**Limitations.** `Sol_cli_release_store.current` still treats a blank `release_id` value in an
existing pointer ConfigMap as "absent" rather than malformed; that is pre-existing behavior shared
with `sol rollback` and was kept in scope here.
