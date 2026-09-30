# CLI test migration to Windtrap inline tests

Every module under `cli/test/` is listed here while the migration is in progress,
so none is lost. `legacy` means it is still run by the `(tests (names ...))`
stanza; `inline` means it moved into `cli/test/inline/`; `explicit executable`
means it stays an executable, with the reason recorded in the last column.

Batch 0 establishes the architecture and moves nothing.

| Module | Model | Batch |
|---|---|---|
| `print_providers.ml` | explicit executable | 1 |
| `print_readiness_invocations.ml` | explicit executable | 1 |
| `test_alert_test.ml` | legacy | 1 |
| `test_alerting.ml` | legacy | 1 |
| `test_boundary_lease.ml` | legacy | 1 |
| `test_bounded_output.ml` | legacy | 1 |
| `test_change_set.ml` | legacy | 1 |
| `test_check.ml` | legacy | 1 |
| `test_cloud_apply.ml` | legacy | 1 |
| `test_cloud_cli.ml` | legacy | 1 |
| `test_cloud_command.ml` | legacy | 1 |
| `test_cloud_destroy.ml` | legacy | 1 |
| `test_cloud_lifecycle.ml` | legacy | 1 |
| `test_cluster_substrate.ml` | legacy | 1 |
| `test_config.ml` | legacy | 1 |
| `test_deploy_event.ml` | legacy | 1 |
| `test_deploy_run.ml` | legacy | 1 |
| `test_deploy_selection.ml` | legacy | 1 |
| `test_deployment.ml` | legacy | 1 |
| `test_deployment_attempt.ml` | legacy | 1 |
| `test_deployment_id.ml` | legacy | 1 |
| `test_deployment_phases.ml` | legacy | 1 |
| `test_deployment_plan.ml` | legacy | 1 |
| `test_deployment_scope.ml` | legacy | 1 |
| `test_deployment_state.ml` | legacy | 1 |
| `test_destination.ml` | legacy | 1 |
| `test_destroy_verification.ml` | legacy | 1 |
| `test_dev_observability.ml` | legacy | 1 |
| `test_disk_quota.ml` | legacy | 1 |
| `test_env_target.ml` | legacy | 1 |
| `test_executor.ml` | legacy | 1 |
| `test_factory.ml` | legacy | 1 |
| `test_fs.ml` | legacy | 1 |
| `test_gcp_absence.ml` | legacy | 1 |
| `test_gcp_outputs.ml` | legacy | 1 |
| `test_image_ref.ml` | legacy | 1 |
| `test_json.ml` | legacy | 1 |
| `test_kube_destination.ml` | legacy | 1 |
| `test_local_infra.ml` | legacy | 1 |
| `test_local_platform.ml` | legacy | 1 |
| `test_local_run.ml` | legacy | 1 |
| `test_logs.ml` | legacy | 1 |
| `test_loki.ml` | legacy | 1 |
| `test_manifest_render.ml` | legacy | 1 |
| `test_manual_job_name.ml` | legacy | 1 |
| `test_migration.ml` | legacy | 1 |
| `test_migration_disposition.ml` | legacy | 1 |
| `test_migration_gate.ml` | legacy | 1 |
| `test_migration_job.ml` | legacy | 1 |
| `test_observability_url.ml` | legacy | 1 |
| `test_open.ml` | legacy | 1 |
| `test_ownership_reconcile.ml` | legacy | 1 |
| `test_platform_assets.ml` | legacy | 1 |
| `test_platform_component.ml` | legacy | 1 |
| `test_port_forward.ml` | legacy | 1 |
| `test_process.ml` | legacy | 1 |
| `test_profile.ml` | legacy | 1 |
| `test_release.ml` | legacy | 1 |
| `test_release_id.ml` | legacy | 1 |
| `test_release_inspection.ml` | legacy | 1 |
| `test_release_retention.ml` | legacy | 1 |
| `test_release_store.ml` | legacy | 1 |
| `test_report.ml` | legacy | 1 |
| `test_rollback.ml` | legacy | 1 |
| `test_rollout_diagnosis.ml` | legacy | 1 |
| `test_run_log.ml` | legacy | 1 |
| `test_runtime_secret_identity.ml` | legacy | 1 |
| `test_scaffold.ml` | legacy | 1 |
| `test_secret.ml` | legacy | 1 |
| `test_secret_reads.ml` | legacy | 1 |
| `test_secret_strategy.ml` | legacy | 1 |
| `test_sensitive_vars.ml` | legacy | 1 |
| `test_sol_yml.ml` | legacy | 1 |
| `test_status.ml` | legacy | 1 |
| `test_string.ml` | legacy | 1 |
| `test_substrate.ml` | legacy | 1 |
| `test_supervised.ml` | legacy | 1 |
| `test_target_report.ml` | legacy | 1 |
| `test_terraform_outputs.ml` | legacy | 1 |
| `test_terraform_plan.ml` | legacy | 1 |
| `test_terraform_workdir.ml` | legacy | 1 |
| `test_time.ml` | legacy | 1 |
| `test_toml_keys.ml` | legacy | 1 |
| `test_tool_adapters.ml` | legacy | 1 |
| `test_up_plan.ml` | legacy | 1 |
| `test_workload_selection.ml` | legacy | 1 |
| `test_workspace.ml` | legacy | 1 |
| `test_workspace_model.ml` | legacy | 1 |
| `test_yaml.ml` | legacy | 1 |
