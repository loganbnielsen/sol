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
    [Apply]) in the cluster [ctx] names. [env], when supplied, is threaded into
    rendered manifest labels.

    FEAT-063: the destination is a required parameter and is never resolved
    here; it arrives already resolved from the command or hosted boundary.

    [before_apply] is forwarded to {!Sol_cli_executor.run_plan} (FEAT-072): it
    runs before each applied workload so a caller can refresh or lose a
    coordination lease mid-run. *)
val execute
  :  Sol_cli_execution.context
  -> mode:Sol_cli_executor.mode
  -> ?secret_backend:Sol_cli_manifest.secret_backend
  -> ?before_apply:(Sol_cli_deployment_plan.service_spec -> (unit, string) result)
  -> Sol_cli_deployment_plan.t
  -> (Sol_cli_executor.result list, string) result

(** The selection/config half of a {!run}: what to deploy, and with what
    resolved configuration. The execution environment is separate. *)
type request =
  { env : Sol_cli_deployment_plan.env_config
  ; requested_scope : string option
  ; resolved_config : Sol_cli_config.t option
  }

(** [run] combines {!plan_of_services} and {!execute} into one call, returning
    both the plan and its per-service results. This is the entry point hosted
    mode should use. [services] is already resolved, and [ctx] is already
    resolved. *)
val run
  :  Sol_cli_execution.context
  -> request:request
  -> mode:Sol_cli_executor.mode
  -> Sol_cli_manifest.service list
  -> (execution, string) result

(** Derive release-inspection facts from a plan and its execution results,
    preserving plan order. Raises [Invalid_argument] if the lists differ in
    length, which would mean the caller paired mismatched values. *)
val affected_services
  :  plan:Sol_cli_deployment_plan.t
  -> results:Sol_cli_executor.result list
  -> Sol_cli_release_inspection.affected_service list
