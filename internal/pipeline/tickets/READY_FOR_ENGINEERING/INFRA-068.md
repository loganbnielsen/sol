---
id: INFRA-068
type: bug
severity: high
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

Destroy path: no whole-root constructive applies — plan-and-assert every apply, scope reconciliation to an allowlist

**Depends on:** None.

**Finding:** FND-0044 (`internal/pipeline/audits/findings/`).

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding for the command/probe and observed output).

## Problem

After FND-0030's targeted preparation, `cloud_destroy` runs `destroy-reconciliation-apply` and `provisioner-bootstrap-access-remove` as `whole_root` applies, which create anything configured but missing from state — the Attempt-6 shape. "Substrate exists" is decided via install-time outputs, so a partial-outputs state is refused outright.

## Remediation

First, replay offline: `terraform output -json` and `terraform plan` (destroy vars + bootstrap enabled) against a copy of the frozen Attempt-6 state, and record which case applies in FND-0044. Then: plan every destroy-path apply and refuse any create/replace outside an explicit allowlist (the bootstrap-access window resource); scope reconciliation to that resource plus eligible guarded addresses; decide substrate existence from state.

## Acceptance criteria

- FND-0044 records the offline replay result (command + observed output).
- An offline test with a state fixture of the Attempt-6 shape shows destroy performs zero create operations.
- A partial-outputs state is destroyable (not refused by the outputs parser).
- Demo/example: not applicable (cloud lifecycle internals) — state in completion notes.
