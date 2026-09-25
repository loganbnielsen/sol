# FND-0059 — A declared guarded resource and its Terraform instance address are compared as strings, so a `count`-ed guarded resource is invisible

- **Classification:** `VERIFIED_DEFECT` (static: the declaration, the state-address form and the
  comparison operator are all in the repository; the offline fleet already models the indexed form
  for `module.eks.aws_eks_cluster.this[0]`)
- **State:** `OPEN`
- **First identified:** 2026-09-25, during the FND-0058 fix (the same address-form class, one layer
  over)
- **Provider:** AWS today (its guarded resource is counted); the defect is provider-neutral
- **Derived ticket:** `INFRA-081`
- **Evidence class:** `STATIC`

## What is established

1. `cli/sol/lib/sol_cli_provider_capabilities.ml` declares AWS's guarded resource by a bare address:
   `guarded_addresses = [ "aws_db_instance.postgres" ]`.
2. `platform/infra/aws/main.tf:276-277` declares that resource as counted:
   `resource "aws_db_instance" "postgres" { count = var.create_rds ? 1 : 0 … }`, so Terraform's
   address for it — in plan *and* in `show -json` state — is `aws_db_instance.postgres[0]`.
3. `Sol_cli_cloud_lifecycle.preparations_eligible ~state ~desired` compares them with
   `List.mem` — **string equality**:

   ```ocaml
   let preparations_eligible ~state ~desired =
     List.filter (fun address -> List.mem address state) desired
   ```

   so `"aws_db_instance.postgres"` is never found in a state holding
   `"aws_db_instance.postgres[0]"`.
4. `preparations_unrepresented` is the exact complement, and GCP's destruction module reports its
   result (`cli/sol/lib/sol_cli_gcp_destruction.ml:193-194`).

**Consequences (INFERENCE from 1–4, not a live observation):**

- On AWS the guarded resource is **never eligible**: it is not in the reconciliation's scope and the
  guarded rule never governs it. The RDS deletion-protection lowering still happens, through the
  destroy policy's own variables on the substrate destroy (`rds_deletion_protection=false`), which is
  why no live AWS destroy has shown a symptom.
- The FND-0030 purpose of `preparations_unrepresented` — *"the state does not hold this declared
  resource, so a destroy cannot reach it and it may still exist and remain billable"* — cannot fire
  for a counted guarded resource **on the provider that reports it least**: the declared address is
  permanently "unrepresented" by construction, so the report would be noise at best and, on AWS,
  the reverse case (a genuinely missing database) is not distinguished from it.

## Why this matters and why it is not FND-0058

FND-0058 was a *permission* failure: the authority create the policy allows could not be matched.
This one is an *identity comparison in scope and reporting* failure: a declaration that does not
match the address form Terraform emits. Both come from the same habit — writing a resource's
address as a constant and comparing it to Terraform's instanced address — which is why FND-0058's
fix introduced `Sol_cli_terraform_plan.Resource` (resource, any instance) and this finding asks for
the same semantics where eligibility and reporting are decided.

## Remediation (for the ticket, not this fix)

Compare declared and observed addresses with the instance key understood: the declared form
identifies the resource, the observed form may carry `[0]`, `[37]` or `["key"]`. The rule must stay
as strict as it is now in the other direction — a declared resource that is genuinely absent from
state must still be reported — so the fix is an instance-aware *match*, not a loosened filter.

## Acceptance criteria

- A counted guarded resource (state address `aws_db_instance.postgres[0]`, declaration
  `aws_db_instance.postgres`) is eligible, is targeted, and is governed by the guarded rule.
- A declared guarded resource genuinely absent from state is still reported as unrepresented, with a
  test for each direction.
- The offline fixtures model the instanced address form for the guarded resources as they already do
  for `module.eks.aws_eks_cluster.this[0]`; before this fix, no fixture could have detected it.
