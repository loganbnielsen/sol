type result =
  { namespace : string
  ; name : string
  ; image : string
  }

type mode =
  | Dry_run
  | Emit_to of string
  | Apply

val local
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> release_id:Sol_cli_release_id.t
  -> dry_run:bool
  -> Sol_cli_deployment_plan.service_spec
  -> (result, string) Stdlib.result

val gitops
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> release_id:Sol_cli_release_id.t
  -> dir:string
  -> Sol_cli_deployment_plan.service_spec
  -> (result, string) Stdlib.result

val run_plan
  :  Sol_cli_execution.context
  -> mode:mode
  -> ?before_apply:(Sol_cli_deployment_plan.service_spec -> (unit, string) Stdlib.result)
  -> Sol_cli_deployment_plan.t
  -> (result list, string) Stdlib.result

val local_development_spec
  :  Sol_cli_deployment_plan.service_spec
  -> Sol_cli_deployment_plan.service_spec

(* Direct-deploy apply sequence: refuse an unowned destination, require the
   Sol-managed unit keys, apply namespace + prerequisites, wait for external Secrets
   to materialize, then apply the workload. *)
val apply_workload_phased
  :  ctx:Sol_cli_kube_destination.context
  -> spec:Sol_cli_deployment_plan.service_spec
  -> bundle:Sol_cli_manifest.bundle
  -> (unit, string) Stdlib.result

(* Wait for an applied workload to become ready. A CronJob is applied only. *)
val wait_for_workload_ready
  :  ctx:Sol_cli_kube_destination.context
  -> spec:Sol_cli_deployment_plan.service_spec
  -> (unit, string) Stdlib.result
