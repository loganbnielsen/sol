# CLI test migration to Windtrap inline tests

Every module under `cli/test/` is listed here, so none is lost. `inline` means
it lives in `cli/test/inline/` and registers its cases with `let%test`;
`explicit executable` means it stays an executable, with the reason recorded in
the last column. The legacy `(tests (names ...))` registry is gone.

Batch 0 (PR 743) established the architecture and moved nothing. Batch 1 moved
every ordinary module: the shared registry no longer names anything, and
`dune`'s per-module inline runner replaces the one-executable-per-file layout
with the same process isolation. Each moved module keeps its existing assertions
inside the test bodies, so only discovery changed.

Batch 1 added two shared path helpers rather than hard-coding the inline
runner's depth: `cli/test/inline/cli_binary.ml` locates the built `sol` binary
for the binary-driven tests, and `cli/test/support/source_root.ml` locates the
checkout for the tests that read the `examples/pluto` and `platform/cloud`
fixtures. The inline library declares those fixtures as deps
(`(deps ../../bin/main.exe ../fixtures/terraform-output-gcp-cloud.json
(source_tree ../../../platform/cloud))`), so no test walks out of `_build` by a
fixed number of levels.

| Module | Model | Reason |
|---|---|---|
| `print_providers.ml` | explicit executable | its stdout is the input to the internal provider-inventory check, so it must be the process under test with its own `argv` |
| `print_readiness_invocations.ml` | explicit executable | its stdout is piped to `internal/ci/check_readiness_invocations.sh`, so it must be the process under test with its own `argv` |
| `test_alert_test.ml` | inline |  |
| `test_alerting.ml` | inline |  |
| `test_aws_absence.ml` | inline |  |
| `test_boundary_epoch.ml` | inline |  |
| `test_boundary_lease.ml` | inline |  |
| `test_bounded_output.ml` | inline |  |
| `test_change_set.ml` | inline |  |
| `test_check.ml` | inline |  |
| `test_cloud_apply.ml` | inline |  |
| `test_cloud_cli.ml` | inline |  |
| `test_cloud_command.ml` | inline |  |
| `test_cloud_destroy.ml` | inline |  |
| `test_cloud_lifecycle.ml` | inline |  |
| `test_cluster_substrate.ml` | inline |  |
| `test_config.ml` | inline |  |
| `test_deploy_event.ml` | inline |  |
| `test_deploy_run.ml` | inline |  |
| `test_deploy_selection.ml` | inline |  |
| `test_deployment.ml` | inline |  |
| `test_deployment_attempt.ml` | inline |  |
| `test_deployment_id.ml` | inline |  |
| `test_deployment_phases.ml` | inline |  |
| `test_deployment_plan.ml` | inline |  |
| `test_deployment_scope.ml` | inline |  |
| `test_deployment_state.ml` | inline |  |
| `test_destination.ml` | inline |  |
| `test_destroy_verification.ml` | inline |  |
| `test_dev_observability.ml` | inline |  |
| `test_disk_quota.ml` | inline |  |
| `test_env_target.ml` | inline |  |
| `test_environment_stage.ml` | inline |  |
| `test_executor.ml` | inline |  |
| `test_factory.ml` | inline |  |
| `test_fs.ml` | inline |  |
| `test_gcp_absence.ml` | inline |  |
| `test_gcp_outputs.ml` | inline |  |
| `test_image_ref.ml` | inline |  |
| `test_installation.ml` | inline |  |
| `test_json.ml` | inline |  |
| `test_kube_destination.ml` | inline |  |
| `test_local_infra.ml` | inline |  |
| `test_local_platform.ml` | inline |  |
| `test_local_run.ml` | inline |  |
| `test_log_selector.ml` | inline |  |
| `test_logs.ml` | inline |  |
| `test_loki.ml` | inline |  |
| `test_manifest_render.ml` | inline |  |
| `test_manual_job_name.ml` | inline |  |
| `test_migration.ml` | inline |  |
| `test_migration_disposition.ml` | inline |  |
| `test_migration_gate.ml` | inline |  |
| `test_migration_job.ml` | inline |  |
| `test_observability_url.ml` | inline |  |
| `test_open.ml` | inline |  |
| `test_ownership_reconcile.ml` | inline |  |
| `test_platform_assets.ml` | inline |  |
| `test_platform_component.ml` | inline |  |
| `test_port_forward.ml` | inline |  |
| `test_process.ml` | inline |  |
| `test_profile.ml` | inline |  |
| `test_release.ml` | inline |  |
| `test_release_id.ml` | inline |  |
| `test_release_inspection.ml` | inline |  |
| `test_release_retention.ml` | inline |  |
| `test_release_store.ml` | inline |  |
| `test_report.ml` | inline |  |
| `test_rollback.ml` | inline |  |
| `test_rollout_diagnosis.ml` | inline |  |
| `test_run_log.ml` | inline |  |
| `test_runtime_secret_identity.ml` | inline |  |
| `test_scaffold.ml` | inline |  |
| `test_secret.ml` | inline |  |
| `test_secret_reads.ml` | inline |  |
| `test_secret_rotation.ml` | inline |  |
| `test_secret_strategy.ml` | inline |  |
| `test_sensitive_vars.ml` | inline |  |
| `test_sol_yml.ml` | inline |  |
| `test_status.ml` | inline |  |
| `test_string.ml` | inline |  |
| `test_substrate.ml` | inline |  |
| `test_substrate_contract.ml` | inline |  |
| `test_supervised.ml` | explicit executable | it forks, calls `setsid`, and supervises a child process group; that process-level lifecycle is one of the architecture's retained-executable cases |
| `test_target_report.ml` | inline |  |
| `test_terraform_outputs.ml` | inline |  |
| `test_terraform_plan.ml` | inline |  |
| `test_terraform_workdir.ml` | inline |  |
| `test_time.ml` | inline |  |
| `test_toml_keys.ml` | inline |  |
| `test_tool_adapters.ml` | inline |  |
| `test_up_plan.ml` | inline |  |
| `test_workload_selection.ml` | inline |  |
| `test_workspace.ml` | inline |  |
| `test_workspace_model.ml` | inline |  |
| `test_yaml.ml` | inline |  |
