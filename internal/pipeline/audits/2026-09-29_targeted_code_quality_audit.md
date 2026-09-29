# Targeted code quality audit — 2026-09-29

Audited freshly fetched `origin/main` and canonical `main` at `f52b946cb7602b0942bbe178007a9d04ade750f0`. One new high-severity finding was filed as BUG-083; no finding was implemented.

## Scope and reconciliation

Read the current roadmap, work summary, audit guidance, previous three code-quality reports, all READY ticket names, relevant BACKLOG/DONE records, and the open PR inventory. The twenty previous audit tickets are DONE. The only open PR at audit time was AWS qualification work (#719). REFAC-156/158 still own support-package API shape, so neither was restated.

Traced the new cloud absence and ownership path through provider observations, resource identity rules, Terraform state decoding, import execution, apply/destroy/reconcile controllers, and recovery tests. Also sampled framework lifecycle/CI coverage and the recent rollback/migration findings. This was a targeted scan, not exhaustive cloud qualification or a live provider run.

## BUG-083 — unknown state becomes an empty ownership set

`cli/lib/cloud/sol_cli_cloud_wiring.ml:279-296` converts failed `terraform show -json` into `State_unreadable`, then calls `Sol_cli_cloud_destroy.addresses state`. That function (`cli/lib/cloud/sol_cli_cloud_destroy.ml:111-116`) returns `[]` for both `State_empty` and `State_unreadable`. `Sol_cli_ownership_reconciliation.disposition_of` treats a provider-present resource with no address in that list as `Recover`; `reconcile_ownership` then imports every candidate when `act=true`. The apply and destroy controllers call it with `act=true`, and the explicit command uses `act=not dry_run`. Thus an unreadable backend does not establish that ownership is missing, yet the import decision proceeds as though it does. BUG-083 records the operation-level regression needed.

The positive control is the existing `State_represented` path: `addresses` returns its addresses and `test_recovery_refuses_a_resource_the_state_already_owns` proves that an address becomes `Already_owned`. The existing empty-state recovery test proves the intended recoverable case. Neither test exercises failed or malformed state through `reconcile_ownership`. This is source-traced evidence; no provider state was mutated.

## Candidates retained without tickets

- The resource identity registry and provider observation lists duplicate some names. Their new structural guards and explicit `Unmapped`/ambiguous dispositions already protect much of the drift risk; an additional generic registry refactor has no verified independent impact here.
- `Sol_cli_ownership_reconciliation.matches` uses substring matching. This merits care in future live qualification, but the provider checks filter target names and the observed matching rules were insufficient evidence of a wrong import in a realistic target. No speculative ticket was filed.
- The framework CI unit and integration coverage gap from INFRA-095 is fixed and guarded on current main. The lifecycle, release, rollback, and migration defects from the previous audit waves are DONE; their prior descriptions were not recycled.

Recommended path: provider observation + **readable** Terraform ownership state → typed reconciliation decision → import through Terraform. An unknown state has no import decision.
