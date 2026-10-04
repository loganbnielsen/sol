---
id: REFAC-140
type: refactor
severity: low
title: Split the files that needed section banners
source: comment removal (2026-09-27) -- a file that needs banners to be navigable wants splitting
---

**Depends on:** None.

## The problem

Before comments were removed, 75 OCaml files used two or more section banners (`(* ── name ── *)`) to divide themselves. A banner marks a seam where the file holds more than one thing. The banners are gone; the seams remain.

Measured on `main` at the comment-removal PR's base, counting lines matching `^ *(\* (──|===|---)`, files with two or more:

- `internal/fixtures/local-demo/bin/demo.ml` — 21 banners, 798 lines
- `cli/test/test_manifest_render.ml` — 18 banners, 3008 lines
- `framework/ocaml/kafka-eio-service/test/test_kafka_service.ml` — 16 banners, 991 lines
- `framework/ocaml/kafka-eio-service/test/test_kafka_service_integration.ml` — 16 banners, 1142 lines
- `internal/fixtures/venus/bin/run.ml` — 13 banners, 406 lines
- `framework/ocaml/sol-fn/test/test_fn.ml` — 11 banners, 295 lines
- `cli/test/test_deployment_phases.ml` — 10 banners, 1326 lines
- `internal/tooling/soldev/lib/soldev_merge.ml` — 10 banners, 1076 lines
- `internal/fixtures/local-demo/bin/retry_demo.ml` — 9 banners, 310 lines
- `cli/test/test_deployment_plan.ml` — 9 banners, 1964 lines
- `internal/tooling/soldev/test/test_ticket.ml` — 8 banners, 626 lines
- `framework/ocaml/sol-obs/test/test_sol_obs.ml` — 8 banners, 462 lines
- `cli/test/test_rollback.ml` — 8 banners, 1700 lines
- `cli/test/test_rollout_diagnosis.ml` — 7 banners, 897 lines
- `cli/test/test_release.ml` — 7 banners, 661 lines
- `cli/test/test_env_target.ml` — 7 banners, 338 lines
- `cli/test/test_run_log.ml` — 7 banners, 260 lines
- `internal/tooling/sol_process/test/test_sol_process.ml` — 7 banners, 192 lines
- `cli/test/test_scaffold.ml` — 7 banners, 1190 lines
- `cli/bin/cmd_status.ml` — 6 banners, 664 lines
- `internal/fixtures/local-demo/test/test_e2e.ml` — 6 banners, 621 lines
- `cli/bin/cmd_local.ml` — 6 banners, 519 lines
- `cli/bin/cmd_migrate.ml` — 6 banners, 416 lines
- `cli/lib/workspace/sol_cli_manifest_yaml.ml` — 5 banners, 973 lines
- `cli/lib/workspace/sol_cli_toml.ml` — 5 banners, 943 lines
- `cli/lib/deploy/sol_cli_release.ml` — 5 banners, 651 lines
- `framework/ocaml/sol-svc/test/test_auth.ml` — 5 banners, 620 lines
- `framework/ocaml/sol-svc/lib/service.ml` — 5 banners, 540 lines
- `framework/ocaml/sol-worker/test/test_worker.ml` — 5 banners, 529 lines
- `cli/test/test_status.ml` — 5 banners, 480 lines
- `cli/test/test_tool_adapters.ml` — 5 banners, 475 lines
- `cli/test/test_loki.ml` — 5 banners, 374 lines
- `cli/test/test_logs.ml` — 5 banners, 320 lines
- `cli/lib/workspace/sol_cli_sol_yml.ml` — 5 banners, 304 lines
- `cli/test/test_executor.ml` — 5 banners, 280 lines
- `cli/lib/base/sol_cli_destroy_verification.ml` — 5 banners, 204 lines
- `cli/test/test_profile.ml` — 5 banners, 1494 lines
- `cli/test/test_cloud_destroy.ml` — 5 banners, 1149 lines
- `framework/ocaml/sol-svc/test/test_service.ml` — 4 banners, 791 lines
- `cli/test/test_terraform_plan.ml` — 4 banners, 670 lines
- `cli/lib/deploy/sol_cli_boundary_lease.ml` — 4 banners, 466 lines
- `framework/ocaml/sol-worker/lib/worker.ml` — 4 banners, 439 lines
- `cli/test/test_deployment.ml` — 4 banners, 394 lines
- `cli/test/test_open.ml` — 4 banners, 348 lines
- `cli/test/test_local_run.ml` — 4 banners, 346 lines
- `cli/test/test_workspace_model.ml` — 4 banners, 311 lines
- `cli/lib/workspace/sol_cli_cmd_new.ml` — 4 banners, 290 lines
- `cli/test/test_deployment_state.ml` — 4 banners, 282 lines
- `cli/test/test_cloud_command.ml` — 4 banners, 282 lines
- `cli/test/test_change_set.ml` — 4 banners, 211 lines
- `cli/test/test_secret_strategy.ml` — 4 banners, 130 lines
- `cli/bin/cmd_cloud_tf.ml` — 3 banners, 593 lines
- `internal/tooling/soldev/lib/soldev_ticket.ml` — 3 banners, 490 lines
- `cli/lib/cloud/sol_cli_supervised.ml` — 3 banners, 484 lines
- `cli/test/test_destroy_verification.ml` — 3 banners, 384 lines
- `cli/lib/deploy/sol_cli_deployment.ml` — 3 banners, 348 lines
- `cli/lib/local/sol_cli_local_run.ml` — 3 banners, 309 lines
- `cli/test/test_observability_url.ml` — 3 banners, 292 lines
- `cli/test/test_process.ml` — 3 banners, 204 lines
- `cli/lib/workspace/sol_cli_manifest.ml` — 3 banners, 199 lines
- `framework/ocaml/sol-svc/test/test_routing.ml` — 3 banners, 155 lines
- `cli/lib/deploy/sol_cli_executor.ml` — 3 banners, 155 lines
- `cli/test/test_deploy_event.ml` — 3 banners, 127 lines
- `cli/lib/deploy/sol_cli_rollback.ml` — 2 banners, 896 lines
- `cli/bin/cmd_up.ml` — 2 banners, 577 lines
- `framework/ocaml/sol-jobs/lib/sol_jobs.ml` — 2 banners, 412 lines
- `cli/test/test_supervised.ml` — 2 banners, 409 lines
- `cli/test/test_substrate.ml` — 2 banners, 377 lines
- `framework/ocaml/sol-svc/lib/auth_internal.ml` — 2 banners, 368 lines
- `cli/test/test_workspace.ml` — 2 banners, 323 lines
- `internal/tooling/soldev/test/test_merge.ml` — 2 banners, 312 lines
- `framework/ocaml/sol-fn/lib/fn.ml` — 2 banners, 178 lines
- `cli/lib/cloud/sol_cli_destruction.ml` — 2 banners, 145 lines
- `cli/test/test_deployment_id.ml` — 2 banners, 115 lines
- `cli/lib/cloud/sol_cli_cloud_lifecycle.ml` — 2 banners, 1143 lines

## Remediation

Work through the list largest-first, skipping test files whose banners only group test cases that one suite already groups. Where a banner marked a real seam, split the module along it; the resulting file names replace the banners. Where it marked nothing, leave the file.

## Acceptance criteria

- Each non-test file above is split along its seams, or its completion note says in one line why it is one thing.
- Output and tests unchanged. Demo/example: not applicable. Language parity: no impact.

## Disposition (2026-10-03) — actionable pre-alpha

Premise re-checked against current `origin/main`; the work is still real.
Evidence: the banner seams the ticket enumerates remain; the splitting work is unchanged in scope.

Promoted to `READY_FOR_ENGINEERING/` by the pre-alpha BACKLOG adjudication
.
