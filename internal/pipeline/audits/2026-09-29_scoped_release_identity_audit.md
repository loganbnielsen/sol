# Targeted scoped-release identity audit — 2026-09-29

Audited clean canonical `main == origin/main` at `50672938fd98d434d4759dcf39103e4c4c445713` after reconciling open implementation PRs #727 and #729–731 and merged filing PRs #725, #726, and #728. No finding was implemented.

## Scope and prior findings

Read the roadmap, work summary, audit guidance, existing BUG-077 and BUG-087–091 tickets, their audit reports, current open PRs, release identity and storage, both apply callers, deployment-event recording, rollback resolution, and relevant release tests. BUG-087 owns the pre-lease boundary-read race; this finding is about identity values after a successful scoped apply, even with a stable boundary. The cloud inventory implementation PRs were not duplicated.

## BUG-092 — scoped workload provenance and deployment events name the wrong release

**Status: Open. Severity: High. Category: Data Integrity / Lifecycle.**

`Sol_cli_deployment_plan.of_services_result` hashes the selected specs into `plan.release_id` (`cli/lib/deploy/sol_cli_deployment_plan.ml:932-950`). Both apply paths render manifests with that ID (`cli/bin/cmd_up.ml:285-298`; `cli/lib/deploy/sol_cli_executor.ml:95-105`). With a nonempty inherited boundary, `Sol_cli_release_id.of_boundary` deliberately derives a different ID using the `sol-boundary-v1` encoding (`cli/lib/base/sol_cli_release_id.ml:139-163`). `Sol_cli_release.of_plan_with_boundary` writes that boundary ID to the record *and* every selected workload's `applied_by` (`cli/lib/deploy/sol_cli_release.ml:92-122`). Thus the live workload label is the plan ID while the current release record says it was applied by the boundary ID. `Sol_cli_rollback.verify_workloads` compares those strings exactly (`cli/lib/deploy/sol_cli_rollback.ml:546-568`), so the just-recorded boundary does not verify against the just-applied cluster.

The same split breaks commit-based rollback: `Sol_cli_deployment.of_plan` and deploy events store the plan ID (`cli/lib/deploy/sol_cli_deployment.ml:42-60`; `cli/lib/deploy/sol_cli_deploy_run.ml:151-168`), while `Sol_cli_release_store.record_plan` persists the boundary under its different ID (`cli/lib/deploy/sol_cli_release_store.ml:95-110`). `cmd_rollback --commit` resolves the event's plan ID and then asks the store for `sol-release-<plan-id>` (`cli/lib/deploy/sol_cli_rollback.ml:778-812`; `cli/bin/cmd_rollback.ml:47-53,78-107`), which does not exist for an inherited scoped boundary.

**Concrete sequence:** deploy A+B as boundary X, then update A with `--scope A` as plan ID P. The new complete boundary Y inherits B, so `Y != P`; A's live manifest carries P, but Y records A `applied_by=Y`. A commit lookup returns P and cannot find Y. The positive control is a first/full deploy with no inherited workloads: `of_boundary` returns `of_content`, so record, plan and live IDs agree. BUG-077's test asserts `applied_by=boundary_b.release_id` using a hand-modified plan and constructs expected live state from the record, so it does not exercise the actual renderer or commit lookup.

**Remediation:** make deploy provenance, live labels, release-record identity, and deployment-event resolution distinct where necessary and consistent end-to-end. A scoped record must rederive its own immutable identity, record the actual applied workload ID, verify against live labels, and let `--commit` resolve to the complete persisted boundary. Exercise the real selected-plan → render → record → resolve/verify flow with an inherited workload.

## Rejected candidates and limits

- Migration checksum drift is already FEAT-094 in BACKLOG; no duplicate was filed.
- Encoded HTTP route segments and migration table-name normalization were examined, but no realistic new high-severity failure beyond existing contracts was established.

This is a source/identity-formula reproduction, not a live Kubernetes run. No cluster, provider, broker or database state was mutated. No implementation code was changed.
