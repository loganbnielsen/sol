type t

val start : unit -> t
val deployment_id : t -> Sol_cli_deployment_id.t
val outcome_of : ('a, string) result -> Sol_cli_deployment.outcome

val record
  :  ctx:Sol_cli_kube_destination.context
  -> target:string option
  -> ?release_id:Sol_cli_release_id.t
  -> Sol_cli_deployment_plan.t
  -> t
  -> Sol_cli_deployment.outcome
  -> bool
