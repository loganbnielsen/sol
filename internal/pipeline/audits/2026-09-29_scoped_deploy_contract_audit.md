# Targeted scoped-deployment contract audit — 2026-09-29

Audited clean canonical `main == origin/main` at `2485a3afe5fa3ab5a4d3c75bb244a98c3ae263cb`. PRs #720–725 are merged; BUG-083–087 are already tracked and are not repeated. No finding was implemented.

## Scope and checks

Read the roadmap, work summary, audit guidance, previous targeted audit, existing tickets and open PRs. Traced command-level `sol up`, `sol deploy`, and `sol rollback` through workload selection, plan construction, network-policy rendering, workspace consumer-group state, release records, and rollback. Read the relevant unit tests and past scoped-deployment decision DEC-036, BUG-077, and prior consumer-group guard fixes BUG-025/045. This is a targeted source audit, not live Kubernetes qualification.

## BUG-088 — scoped deploy loses workspace consumer-group state

**Status: Open. Severity: High. Category: Data Integrity.**

`Sol_cli_deployment_plan.of_services_result` filters to selected `resolved_services` (`cli/lib/deploy/sol_cli_deployment_plan.ml:899-950`) and derives `plan.consumer_groups` only from them. Both `cmd_up.ml:38-49,369,407` and `cmd_deploy.ml:30-43,225-230` pass that selected list to `Sol_cli_deployment_state.check_removed_groups`; both later record the same list as the entire workspace state (`cmd_up.ml:407`, `sol_cli_deploy_run.ml:285-299`). The state uses one workspace ConfigMap, and `removed_consumer_groups` subtracts `next` from all `prev` (`cli/lib/kube/sol_cli_deployment_state.ml:11-47,103-122`).

With workers A and B recorded, `sol deploy --scope A` presents only A as `next`. Without `--confirm-group-change`, the normal scoped update is refused as if B were removed. With confirmation, it applies only A but writes only A to the workspace record; a later whole-workspace change removing B can pass without warning because B was forgotten. `test_deployment_state.ml` covers set subtraction and write outcomes, but no scoped caller supplies a partial group set. The group check also runs before the workspace lease in both commands, allowing a competing operation to change the record before apply.

**Remediation:** compare and record the complete post-deploy workspace group set under the same boundary lease as apply/record, preserving unaffected groups for scoped updates. Exercise scoped worker and service updates with at least two groups and an intervening group-state change.

## BUG-089 — scoped callee deploy removes cross-domain ingress

**Status: Open. Severity: High. Category: Runtime / Domain Architecture.**

The plan resolves call targets against the full workspace inventory, as DEC-036 requires, but builds `called_by` from `resolved_services` only (`cli/lib/deploy/sol_cli_deployment_plan.ml:903-930`). For `--scope checkout/checkout_svc`, the caller in another domain is omitted, so the callee's `called_by` becomes `[]`. `Sol_cli_deployment_render` passes it to `network_policy_doc` (`cli/lib/deploy/sol_cli_deployment_render.ml:153-166`), whose ingress list contains only platform/same-namespace sources plus explicit cross-namespace callers (`cli/lib/workspace/sol_cli_manifest_yaml.ml:605-654`). Applying the selected callee overwrites its NetworkPolicy without the caller rule. The caller remains deployed and its own egress rule still targets the callee, but traffic across domain namespaces is denied.

The full-plan test at `cli/test/test_deployment_plan.ml:1360-1391` asserts a callee has one caller, and the renderer test at `cli/test/test_manifest_render.ml:306-359` asserts that caller appears in ingress. Neither tests a callee-only selection. This is deterministic source and render-path evidence; no live policy engine was exercised.

**Remediation:** derive incoming call edges from the full workspace inventory while rendering only selected workloads. A regression should render a callee-only scope with an unselected cross-domain caller and retain its ingress rule; a misspelled call target must still fail closed.

## BUG-090 — rollback leaves the consumer-group guard at the newer release

**Status: Open. Severity: High. Category: Data Integrity / Lifecycle.**

`cmd_rollback.run_locked` (`cli/bin/cmd_rollback.ml:40-91`) re-applies recorded workloads, prunes surplus, and moves/verifies the current release pointer through `Sol_cli_rollback.execute` (`cli/lib/deploy/sol_cli_rollback.ml:690-755`). It never updates `Sol_cli_deployment_state`'s workspace consumer-group ConfigMap, which is updated only by successful `sol up`/`sol deploy`. The release record carries no consumer-group list, so the guard can describe the release *before* rollback rather than the workloads now running.

Example: release R1 has group A; R2 adds group B. Roll back to R1: B's workload is pruned, yet the guard still records A+B. A subsequent deploy of R2 is considered group-preserving; a subsequent deploy of R1 is spuriously warned that B is being removed. In the reverse direction (R1 to R2 rollback), a subsequent removal of B can pass without the intended confirmation. Existing rollback tests verify workloads and pointer, not this state.

**Remediation:** make the post-rollback consumer-group set part of the verified release transition, updating the safety record only after the restored workloads and pointer have been verified. Cover both rollback directions and the following deploy's group-change check.

## Candidates rejected and limits

- `sol up --scope` still plans cross-domain calls against its selected set, unlike `sol deploy`'s explicit inventory. This appears to block a scoped caller before mutation; it is lower severity than the verified runtime and guard defects here, so no ticket was filed.
- The prior BUG-087 boundary-read race is already filed and merged as a ticket, with implementation outstanding; it was not relabeled as a new finding.

No provider, Kubernetes, broker, or database state was mutated. The three findings are source-traced interleavings or deterministic plan/render behavior; their implementation tickets require focused executable regressions. No source code was changed.
