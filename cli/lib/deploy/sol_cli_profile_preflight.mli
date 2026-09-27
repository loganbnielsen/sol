type side =
  | Application
  | Target
  | Platform

type status =
  | Established
  | Unmet of side * string

type finding =
  { capability : Sol_cli_profile.capability
  ; side : side
  ; reason : string
  }

val establish
  :  target:Sol_cli_config.target
  -> apply_mode:Sol_cli_release.apply_mode
  -> plan:Sol_cli_deployment_plan.t
  -> Sol_cli_profile.capability
  -> status

val check
  :  ?establish:(Sol_cli_profile.capability -> status)
  -> target:Sol_cli_config.target
  -> apply_mode:Sol_cli_release.apply_mode
  -> Sol_cli_deployment_plan.t
  -> (unit, Sol_cli_profile.t * finding list) result

val side_to_string : side -> string
val finding_to_string : finding -> string
val report : Sol_cli_profile.t -> finding list -> string
