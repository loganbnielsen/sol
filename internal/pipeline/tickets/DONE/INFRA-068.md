---
id: INFRA-068
type: bug
severity: high
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

Destroy path: no whole-root constructive applies — plan-and-assert every apply, scope reconciliation to an allowlist

**Depends on:** REFAC-091.

**Finding:** FND-0044 (`internal/pipeline/audits/findings/`).

**Sequencing:** this is step 3 of the HARDEN-004 order in `internal/pipeline/audits/HARDEN-004-handoff.md` ("The order now"). Coordinate with the HARDEN-004 owner; land it as that step, not in parallel.

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding for the command/probe and observed output).

## Problem

After FND-0030's targeted preparation, `cloud_destroy` runs `destroy-reconciliation-apply` and `provisioner-bootstrap-access-remove` as `whole_root` applies, which create anything configured but missing from state — the Attempt-6 shape. "Substrate exists" is decided via install-time outputs, so a partial-outputs state is refused outright.

## Remediation

The offline Attempt-6 replay is the handoff's step 1 (a doc PR); if it has not landed, do it first: `terraform output -json` and `terraform plan` (destroy vars + bootstrap enabled) against a copy of the frozen Attempt-6 state, and record which case applies in FND-0044. Then: plan every destroy-path apply and refuse any create/replace outside an explicit allowlist (the bootstrap-access window resource); scope reconciliation to that resource plus eligible guarded addresses; decide substrate existence from state.

## Acceptance criteria

- FND-0044 records the offline replay result (command + observed output).
- An offline test with a state fixture of the Attempt-6 shape shows destroy performs zero create operations.
- Demo/example: not applicable (cloud lifecycle internals) — state in completion notes.

## Completion notes (2026-09-24, recorded retroactively)

Implemented by HARDEN-004 part 2 (#462, state inventory; existence from state) and part 3 (#463,
plan-and-assert on every destroy-path apply; reconciliation scoped to bootstrap + represented guarded
addresses). Those PRs were named after the HARDEN-004 epic, so the Ticket-move guard never moved this
ticket; it is moved here as bookkeeping.

- Criterion 1: the offline replay was **ruled out**, not run (#461; recorded in FND-0044's
  2026-09-24 transition).
- Criterion 2: met by `test_whole_root_missing_cluster_create_is_refused` and "Attempt-6 inventory
  prunes the scope" (`cli/sol/test/test_terraform_plan.ml`) plus the offline harness's refusal
  scenario.
- Demo/example: not applicable (cloud lifecycle internals).
- Note: `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md` keeps this
  behaviour (destroy never constructs) and simplifies its per-phase policies (REFAC-094).
- Its declared dependency REFAC-091 is only half done: the destroy half this ticket needed landed
  in #462 and #463; the install half remains open as REFAC-091 (plan § S7).
