module Severity : sig
  type t =
    | Error
    | Warning
end

type finding =
  { severity : Severity.t
  ; path : string
  ; message : string
  }

val finding_to_string : finding -> string
val run : facts:Sol_cli_workspace_model.t -> finding list

val run_services
  :  facts:Sol_cli_workspace_model.t
  -> Sol_cli_manifest.service list
  -> finding list

val declaration_findings : facts:Sol_cli_workspace_model.t -> finding list

val declaration_findings_in_scope
  :  facts:Sol_cli_workspace_model.t
  -> Sol_cli_deployment_scope.request
  -> finding list

val has_errors : finding list -> bool
