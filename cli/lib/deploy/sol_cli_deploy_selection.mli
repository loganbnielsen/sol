type selection =
  { resolved : Sol_cli_workload_selection.resolved
  ; image_refs : (string * string) list
  }

val select
  :  image_refs:(string option * string) list
  -> Sol_cli_manifest.service list
  -> (selection, string) result

type deployed =
  { services : Sol_cli_manifest.service list
  ; notes : string list
  }

val apply_target
  :  target:string
  -> config:Sol_cli_config.t
  -> selection
  -> (deployed, string) result

val secret_authorities_for_plan
  :  config:Sol_cli_config.t
  -> Sol_cli_deployment_plan.t
  -> ((string * string * Sol_cli_config.secret_authority) list, string) result

type plan_error =
  | Refused of string
  | Preflight of Sol_cli_profile.t * Sol_cli_profile_preflight.finding list

module Planning_input : sig
  type t =
    { workspace : string
    ; registry : string
    ; sha : string
    ; emit_to : string option
    ; config : Sol_cli_config.t
    ; facts : Sol_cli_workspace_model.t
    ; inventory : Sol_cli_manifest.service list
    ; requested_scope : string
    ; image_refs : (string * string) list
    ; services : Sol_cli_manifest.service list
    }
end

module Target_plan_input : sig
  type t =
    { workspace : string
    ; registry : string
    ; sha : string
    ; emit_to : string option
    ; config : Sol_cli_config.t
    ; facts : Sol_cli_workspace_model.t
    ; inventory : Sol_cli_manifest.service list
    ; image_refs : (string * string) list
    ; services : Sol_cli_manifest.service list
    }
end

module Target_plan : sig
  type t

  val profile : t -> Sol_cli_deployment_plan.profile_claim option
  val to_deployment_plan : t -> Sol_cli_deployment_plan.t
end

val plan : Planning_input.t -> (Sol_cli_deployment_plan.t, plan_error) result
val target_plan : Target_plan_input.t -> (Target_plan.t, plan_error) result
