type failure =
  | Destroy_failed of string
  | Retirement_failed of string
  | Verification_failed of string

type outcome =
  | Uninstall_refused of string
  | Uninstall_succeeded of Sol_cli_installation.prerequisite list
  | Uninstall_failed of
      { failure : failure
      ; verification : Sol_cli_installation_uninstall.removal_verification
      }

type deps =
  { release_state_backend : unit -> (unit, string) result
  ; unmanage_zone : unit -> (unit, string) result
  ; destroy : unit -> (unit, string) result
  ; retire_state_backend : unit -> (unit, string) result
  ; observe :
      unit -> (Sol_cli_installation.prerequisite * Sol_cli_installation.verdict) list
  ; warn : string -> unit
  }

val failure_message : failure -> string

val execute
  :  deps:deps
  -> plan:Sol_cli_installation_uninstall.plan
  -> state_backend_in_state:bool
  -> confirm:bool
  -> dns_confirmation:string option
  -> outcome
