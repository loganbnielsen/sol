type selection =
  { requested_scope : string
  ; resolved : Sol_cli_workload_selection.resolved
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

type plan_error =
  | Refused of string
  | Preflight of Sol_cli_profile.t * Sol_cli_profile_preflight.finding list

module Planning_input : sig
  type t =
    { workspace : string
    ; registry : string
    ; sha : string
    ; emit_to : string option
    ; secret_backend : Sol_cli_manifest.secret_backend
    ; config : Sol_cli_config.t
    ; facts : Sol_cli_workspace_model.t
    ; inventory : Sol_cli_manifest.service list
    ; requested_scope : string
    ; image_refs : (string * string) list
    ; services : Sol_cli_manifest.service list
    }
end

val plan : Planning_input.t -> (Sol_cli_deployment_plan.t, plan_error) result
