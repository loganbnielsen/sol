(** Internal factory boundary (CODE_LAYER-018).

    A Cmdliner-free composition of the workspace scan, deployment-plan,
    execution, and release-fact stages. Hosted mode should call this module
    rather than command handlers; CLI commands can delegate their plan/execute
    work here while keeping their current UX.

    The pipeline is:

    {[
      workspace scan -> deployment plan -> execution -> release facts
    ]} *)

(** Plan plus the per-service results produced by executing it. *)
type execution =
  { plan : Sol_cli_deployment_plan.t
  ; results : Sol_cli_executor.result list
  }

(** Build a deployment plan from an already-resolved service list. This is the
    only entry point: selection happens once, at the command (or hosted-handler)
    boundary, via [Sol_cli_workload_selection], so the factory never scans the
    workspace and cannot select a different set than the caller asked for
    (FEAT-065). *)
val plan_of_services
  :  workspace:string
  -> env:Sol_cli_deployment_plan.env_config
  -> ?requested_scope:string
  -> ?resolved_config:Sol_cli_config.t
  -> Sol_cli_manifest.service list
  -> (Sol_cli_deployment_plan.t, string) result

(** Execute every service in the plan under [mode] ([Dry_run], [Emit_to], or
    [Apply]). [env], when supplied, is threaded into rendered manifest labels.
*)
val execute
  :  workspace:string
  -> ?env:string
  -> mode:Sol_cli_executor.mode
  -> ?secret_backend:Sol_cli_manifest.secret_backend
  -> Sol_cli_deployment_plan.t
  -> (Sol_cli_executor.result list, string) result

(** [run] combines {!plan_of_services} and {!execute} into one call, returning
    both the plan and its per-service results. This is the entry point hosted
    mode should use. [services] is already resolved. *)
val run
  :  workspace:string
  -> env:Sol_cli_deployment_plan.env_config
  -> ?env_label:string
  -> ?requested_scope:string
  -> ?resolved_config:Sol_cli_config.t
  -> mode:Sol_cli_executor.mode
  -> Sol_cli_manifest.service list
  -> unit
  -> (execution, string) result

(** Derive release-inspection facts from a plan and its execution results,
    preserving plan order. Raises [Invalid_argument] if the lists differ in
    length, which would mean the caller paired mismatched values. *)
val affected_services
  :  plan:Sol_cli_deployment_plan.t
  -> results:Sol_cli_executor.result list
  -> Sol_cli_release_inspection.affected_service list
