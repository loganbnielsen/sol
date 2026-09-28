---
id: REFAC-152
type: refactor
severity: medium
title: Replace loose parameter swarms with explicit domain inputs
source: Logan code review (2026-09-27), generalized from REFAC-145
---

Replace loose parameter swarms with explicit domain inputs

**Depends on:** None.

**Premise verified (2026-09-27):** REFAC-145 found 20/21-argument Deployment and
Rollout builders in `sol_cli_manifest.mli`. The style-audit sweep also found the
27-argument internal retry-topic consumer in
`kafka_service_retry_topics.mli`. These are positive controls for the broader API shape,
not an exhaustive inventory.

## The principle — explicit domain grouping

When several arguments travel together as one real concept, represent that concept with
a named record or variant and validate it before the call. Labels make a long call
legible but do not let the compiler ensure that related paths receive the same value.

Do not replace every long signature with a vague `deps` bag. Keep labels when inputs are
few and independent; use a record for a real request/spec/config/runtime value, a variant
when valid fields differ by mode, or split the function when the arguments belong to
sequential phases.

## Remediation

- Audit public `.mli` files first, then widely used internal functions across
  `cli/lib/deploy`, `cli/lib/workspace`, `cli/lib/cloud`, `framework/ocaml`, and
  `internal/tooling` for more than five or six primitive/config-fragment arguments.
- Trace every caller before choosing labels, a domain record, a mode-specific variant,
  or a phase split.
- Include repeated optional/defaulted arguments: a long optional list is still a swarm
  when callers must remember one invariant across several paths.
- Reuse existing domain types before introducing a new one.

## Acceptance criteria

- Completion notes inventory every public signature above the threshold with a verdict:
  already cohesive, grouped, variant/split, or deliberately retained.
- High-confidence swarms become named domain values or phase boundaries; no vague
  dependencies record is introduced.
- Callers construct each domain value once and share it across paths that must agree.
- Focused tests prove the invariant the new type makes unrepresentable or single-source.
- Demo/example and language-parity impact are recorded per changed API.

## Completion (2026-09-28)

- Rechecked all public declarations and representative callers across cli/lib,
  framework/ocaml and internal/tooling. The inventory below counts optional and
  positional inputs plus trailing unit, but excludes arrows inside callback types.
  122 tracked interfaces yielded 28 public signatures above six arguments before
  these changes; deployment_doc (21) was the positive control.
- Cloud wiring now reuses validated cloud_target for target/provider/backends/root
  paths and derives the display name. A `terraform_layout` value (provider, pname,
  cluster and platform workdirs, and both backend configs) is produced once from the
  cloud target and shared by plan/apply/destroy, so the four entry points can no
  longer derive contradictory paths; a `terraform_inputs` value carries the
  caller-supplied var_files/vars. A focused test in `test_cloud_lifecycle` constructs
  a cloud target and asserts the layout follows its provider and backends and that
  the two roles never share a workdir.
- Scheduled_workload_spec names the CronJob render contract without forcing fn
  workloads into the unrelated Deployment/Rollout specification. Planning_input
  names resolved deploy-planning data without depending on the effectful deploy
  execution context; callers normalize it once.

### Exhaustive public-signature inventory

Paths are under cli/lib unless marked framework. Counts describe the discovery
baseline; grouped entries list the new count. Every over-threshold declaration is
accounted for, not just the signatures changed here.

| Interface | Function(s) and original count | Verdict |
| --- | --- | --- |
| cloud/sol_cli_cloud_wiring | plan 10, apply_deps 12, destroy_preview 8, destroy_deps 11 | Grouped/derived: 4, 5, 4, 6 |
| cloud/sol_cli_terraform | plan_saved 7 | Retained independent native options and saved-plan output |
| deploy/sol_cli_command_request | make_deploy_request 13 | Already cohesive output request; raw CLI normalization boundary |
| deploy/sol_cli_deploy_selection | plan 11 | Grouped into Planning_input (1) |
| deploy/sol_cli_deployment | of_plan 8 | Retained independent provenance facts in a record constructor |
| deploy/sol_cli_deployment_plan | of_services_result 8 | Already groups environment config; remaining selection/facts/inventory inputs have distinct roles |
| deploy/sol_cli_factory | plan_of_services 8 | Retained same planner boundary, not a second context wrapper |
| deploy/sol_cli_release_inspection | release_summary 7 | Retained straightforward record/provenance builder |
| kube/sol_cli_helm | upgrade_install 7 | Retained independently selectable native Helm options |
| workspace/sol_cli_manifest | external_secret_doc 7 | Retained explicit store configuration, secret selection and object identity; caller already owns External_secrets variant |
| workspace/sol_cli_manifest | deployment_doc 21, rollout_doc 21 | Grouped by REFAC-145 into Workload_spec and wrapper strategy |
| workspace/sol_cli_manifest | ingress_doc 7 | Retained independently defaulted ingress/TLS options |
| workspace/sol_cli_manifest | cronjob_doc 14 | Grouped into Scheduled_workload_spec (1) |
| framework/kafka-eio-service/kafka_service | Retry_topics.route_decode_error 8 | Retained explicit message/error/effect test seam |
| framework/kafka-eio-service/kafka_service | consume 13, consume_partitioned 17 | Already accepts service/topic; independent public lifecycle and policy options remain explicit |
| framework/sol-jobs/sol_jobs | Make.run 12 | Already groups timed environment; independent pool/polling/retry/hooks |
| framework/sol-obs/sol_obs | of_env 7 | Already groups context; explicit Eio capabilities, not primitive fragments |
| framework/sol-svc/service | Make.run 10, run 11 | Already groups environment/config; independent server lifecycle options and routes |
| framework/sol-worker/worker | Make.run 8, Make_with_retry.run 10, For_testing.Make.run 9, For_testing.Make_with_retry.run 11 | Already groups environment/config; independent lifecycle/policy and deliberate testing seams |

Internal tooling has no qualifying public interface signature in this inventory.
Two private retry-topic declarations were also inspected: consume is grouped by
REFAC-146 into runtime; route_decode_error remains an explicit policy test seam.
REFAC-146's shared process_handler_result also deliberately keeps its policy/message/
effect test inputs explicit rather than adding a generic dependencies record.

- Validation: CLI build, formatting, all manifest-render tests, deploy-selection,
  cloud apply/destroy unit suites, the new terraform-layout focused test, and the
  real-command offline lifecycle scenarios.
- Demo/example: internal signature changes only; existing generated manifests and
  deploy/cloud behavior stay unchanged and their existing runnable examples apply.
  No language-parity impact: no framework or deployment convention changes.
