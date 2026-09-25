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
