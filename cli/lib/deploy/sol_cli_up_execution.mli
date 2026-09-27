type service_execution =
  { k8s_name : string
  ; namespace : string
  ; push_image : string
  ; context : string
  ; dockerfile : string
  ; source_dir : string
  }

type post_deploy_summary =
  { deployed_count : int
  ; pending_migrations : int
  }

val push_registry : string
val build_context_dir : repo_root:string -> string

(** BUG-056: [declared] is what the workspace's [sol.yml] declares
    ({!Sol_cli_config.load_declared}), so a local plan carries the same declared
    language, scale and resource uses a target's plan does. *)
val local_plan
  :  requested_scope:string
  -> workspace:string
  -> sha:string
  -> facts:Sol_cli_workspace_model.t
  -> declared:Sol_cli_config.declared
  -> Sol_cli_manifest.service list
  -> (Sol_cli_deployment_plan.t, Sol_cli_deployment_plan.plan_error) result

val manifest_primitive : Sol_cli_deployment_plan.primitive -> Sol_cli_manifest.primitive

val service_execution
  :  workspace:string
  -> ctx_dir:string
  -> sha:string
  -> Sol_cli_deployment_plan.service_spec
  -> service_execution

val dry_run_spec
  :  workspace:string
  -> sha:string
  -> Sol_cli_deployment_plan.service_spec
  -> Sol_cli_deployment_plan.service_spec

val prepare_build_context : repo_root:string -> (string, string) result
val remove_build_context : ctx_dir:string -> unit
val build_image : service_execution -> (unit, string) result
val push_image : service_execution -> (unit, string) result

val apply_service_manifest
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> release_id:Sol_cli_release_id.t
  -> dry_run:bool
  -> Sol_cli_deployment_plan.service_spec
  -> (Sol_cli_executor.result, string) result

(** FEAT-063: the rollout is watched in the cluster the target names. *)
val wait_for_service_rollout
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_deployment_plan.service_spec
  -> service_execution
  -> (unit, string) result

(** REFAC-130: the pending-migration count is a projection of the workspace the
    command already read ([Sol_cli_workspace_model.count_unapplied_migrations]),
    not a second walk of [db/migrations]. *)
val post_deploy_summary
  :  facts:Sol_cli_workspace_model.t
  -> Sol_cli_deployment_plan.t
  -> post_deploy_summary

val record_applied
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> sha:string
  -> Sol_cli_deployment_plan.t
  -> (unit, string) result
