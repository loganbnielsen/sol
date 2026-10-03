---
id: INFRA-081
type: bug
severity: medium
title: A declared guarded resource and its Terraform instance address are compared as strings
source: FND-0059 (found while fixing FND-0058 — the same address-form class)
---

**Depends on:** None.

**Finding:** `internal/pipeline/audits/findings/FND-0059-declared-guarded-addresses-are-compared-as-strings.md`.

**Related:** FND-0058 / `INFRA-079` (where the same class caused a real refusal), FND-0030 (the
reporting purpose `preparations_unrepresented` exists for), `Sol_cli_terraform_plan.Resource`.

## Problem

`preparations_eligible ~state ~desired` compares a declared address with a state address using
string equality. AWS's guarded resource is declared as `aws_db_instance.postgres` and Terraform
names it `aws_db_instance.postgres[0]` (it is `count`-ed), so it is never eligible: the guarded rule
never governs it and the FND-0030 unrepresented report cannot distinguish it from a genuinely
missing resource.

## Remediation

Match declared against observed with the Terraform instance key understood — the declared form
identifies the resource; the observed form may carry `[0]`, `[37]` or `["key"]`. The helper
introduced for FND-0058 (`Sol_cli_terraform_plan.Resource`, "this resource, any instance") is the
same semantic; reuse it rather than writing a second comparison. Keep the negative direction strict:
a declared resource genuinely absent from state must still be reported.

## Acceptance criteria

- A counted guarded resource is eligible, targeted, and governed by the guarded rule (test).
- A declared guarded resource absent from state is still reported unrepresented (test).
- Offline fixtures model the instanced address form for guarded resources, as they already do for
  `module.eks.aws_eks_cluster.this[0]`.

## Disposition (2026-10-03) — actionable pre-alpha

Premise re-checked against current `origin/main`; the work is still real.
Evidence: `Sol_cli_cloud_lifecycle.preparations_eligible` still uses `List.mem address state` (string equality) on instanced addresses.

Promoted to `READY_FOR_ENGINEERING/` by the pre-alpha BACKLOG adjudication
(`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`).

## Completion notes (2026-10-03)

**Premise re-verified.** `Sol_cli_cloud_lifecycle.preparations_eligible`
(and `preparations_unrepresented`) compared declared addresses to state with
`List.mem`, i.e. string equality, so a declared `aws_db_instance.postgres` never
matched state's counted `aws_db_instance.postgres[0]`.

**Fix.** Added `Sol_cli_terraform_plan.same_resource`, which strips the Terraform
instance key from both addresses via the existing `without_instance_key` helper
(the one FND-0058 / INFRA-079 introduced for the `Resource` matcher), and used it
in `represented_in`, which both `preparations_eligible` and
`preparations_unrepresented` now share. The declared form identifies the
resource; the observed form may carry `[0]`, `[37]` or `["key"]`. The negative
direction stays strict: a declared resource with no state instance is still
unrepresented.

**Tests.** `cli/test/inline/test_cloud_lifecycle.ml` adds three cases: a counted
state address satisfies the declared address, a string-keyed instance does too,
and a declared resource with no matching instance is still unrepresented. The
inline suite runs 54 tests; the three new ones pass. Two unrelated
scaffold-compile tests (`Test_scaffold › existing_files: scaffold actually
compiles`, `bare fn library compiles`) fail in this fresh worktree because the
scaffold's dev-channel opam pin is not installed locally; they are not touched by
this change and are green under CI's `ci-unit`.

**Demo/example coverage:** not applicable — cloud-lifecycle internals.
**Language parity (DEC-022):** no application-facing change.
