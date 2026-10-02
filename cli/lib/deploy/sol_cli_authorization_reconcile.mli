type terraform_grant =
  { unit : string
  ; capability : string
  ; resource : string
  ; namespace : string
  }

val desired
  :  Sol_cli_workspace_model.t
  -> (Sol_cli_authorization.grant list, string) result

val terraform_grants
  :  grants:Sol_cli_authorization.grant list
  -> namespace_of:(string -> string option)
  -> (terraform_grant list, string) result

val terraform_var : terraform_grant list -> string * string
val current_of_output_json : string -> (Sol_cli_authorization.grant list, string) result

val deployed_of_listing_json
  :  namespaces:string list
  -> string
  -> (Sol_cli_authorization.grant list, string) result
