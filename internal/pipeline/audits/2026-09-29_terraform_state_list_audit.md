# Targeted Terraform state-list audit — 2026-09-29

Audited synced `origin/main` `cd3251a5aedd8ef6d7bc15bf00f018a56b66e34d`. BUG-094 is a new high-severity cloud lifecycle finding. No implementation was made.

## Finding: a state-list error becomes absence during cluster resolution

`Sol_cli_provider_registry.state_holds_any` (`cli/lib/cloud/sol_cli_provider_registry.ml:31-43`) returns `false` for every error from `terraform state list`. `of_root` first reads and parses `terraform output -json`, but returns `Ok None` when `state_holds_any` returns false (`:45-57`). Therefore a successful output read plus a failed state-list command is represented exactly like a confirmed cluster absence. The same collapse applies to AWS and GCP; the identifying state address differs by provider.

This result reaches both `Sol_cli_cloud_apply` and `Sol_cli_cloud_destroy` through `cluster_of`. In apply, `substrate_exists` calls `cluster_of` (`sol_cli_cloud_wiring.ml:400-403`), so it can report a bootstrap phase for an existing cluster. In destroy, `observe_state` uses a separate `terraform show -json` read to establish `Substrate_present` (`sol_cli_cloud_wiring.ml:813-823`), while `cloud_outputs` calls `cluster_of` (`:825-835`). If `terraform output -json` succeeds and `terraform state list` fails, destroy sees `Substrate_present` plus `Outputs_unavailable`; `Sol_cli_cloud_destroy.teardown` (`cli/lib/cloud/sol_cli_cloud_destroy.ml:267-280`) skips platform teardown and continues to destroy the represented cloud substrate. This is an avoidable loss of a platform teardown attempt caused by a failed read, with potential retained load balancers/volumes and incomplete cleanup. A failed `terraform state list` can be modeled by a command stub while the separate `output` and `show` calls succeed; no live provider destroy was run.

The positive control is an empty successful `terraform state list`, which may correctly yield `Ok None` even when output JSON is valid. A nonempty successful listing containing the provider's identifying resource yields `Some cluster`. The failed read must be a third state, not one of those two.

## Reconciliation

This is separate from BUG-083 (ownership imports on unreadable Terraform state) and BUG-085 (unobservable provider inventory checks). Those concern reconcile; this finding is in the shared cluster resolver used by apply, plan, and destroy. No ticket or test for `state_holds_any` failure was found by `rg -n 'state_holds_any|state list.*output|cluster_of.*None' cli/test internal/pipeline/tickets internal/pipeline/audits`; the positive control is the matching `state_holds_any` declaration and call in `sol_cli_provider_registry.ml`.
