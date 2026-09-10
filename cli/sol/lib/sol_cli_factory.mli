(** Internal factory boundary (CODE_LAYER-018).

    A Cmdliner-free composition of the workspace scan, deployment-plan,
    execution, and release-fact stages. Hosted mode should call this module
    rather than command handlers; CLI commands can delegate their plan/execute
    work here while keeping their current UX.

    The pipeline is:

    {[
      workspace scan -> deployment plan -> execution -> release facts
    ]} *)

type execution = {
  plan : Sol_cli_deployment_plan.t;
  results : Sol_cli_executor.result list;
}
(** Plan plus the per-service results produced by executing it. *)

val plan_of_services :
  workspace:string ->
  env:Sol_cli_deployment_plan.env_config ->
  ?resolved_config:Sol_cli_config.t ->
  Sol_cli_manifest.service list ->
  (Sol_cli_deployment_plan.t, string) result
(** Build a deployment plan from an already-discovered service list. This is the
    variant CLI commands with their own filtering use; {!plan} is the
    workspace-scanning variant hosted mode uses. *)

val plan :
  workspace:string ->
  env:Sol_cli_deployment_plan.env_config ->
  filter_path:string option ->
  (Sol_cli_deployment_plan.t, string) result
(** Discover workloads and build a deployment plan. Returns an actionable error
    string when discovery or plan construction fails instead of exiting; callers
    without a console decide how to present it. *)

val execute :
  workspace:string ->
  ?env:string ->
  mode:Sol_cli_executor.mode ->
  ?secret_backend:Sol_cli_manifest.secret_backend ->
  Sol_cli_deployment_plan.t ->
  (Sol_cli_executor.result list, string) result
(** Execute every service in the plan under [mode] ([Dry_run], [Emit_to], or
    [Apply]). [env], when supplied, is threaded into rendered manifest labels.
*)

val run :
  workspace:string ->
  env:Sol_cli_deployment_plan.env_config ->
  ?env_label:string ->
  filter_path:string option ->
  mode:Sol_cli_executor.mode ->
  unit ->
  (execution, string) result
(** [run] combines {!plan} and {!execute} into one call, returning both the plan
    and its per-service results. This is the entry point hosted mode should use.
*)

val affected_services :
  plan:Sol_cli_deployment_plan.t ->
  results:Sol_cli_executor.result list ->
  Sol_cli_release_inspection.affected_service list
(** Derive release-inspection facts from a plan and its execution results,
    preserving plan order. Raises [Invalid_argument] if the lists differ in
    length, which would mean the caller paired mismatched values. *)
