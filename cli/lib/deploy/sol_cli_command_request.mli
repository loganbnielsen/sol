type execution_mode =
  | Dry_run
  | Apply

type deploy_action =
  | Deploy_dry_run of { emit_to : string option }
  | Deploy_emit_to of string
  | Deploy_apply

type up_request =
  { scope : string option
  ; mode : execution_mode
  ; image_tag : string
  ; image_tag_warning : string option
  ; confirm_group_change : bool
  ; keep_releases : int
  }

type deploy_request =
  { target : string
  ; scope : string option
  ; action : deploy_action
  ; emit_plan_to : string option
  ; image_tag : string
  ; image_refs : (string option * string) list
  ; registry : string option
  ; secret_backend : Sol_cli_manifest.secret_backend option
  ; confirm_group_change : bool
  ; loki_push_url : string option
  ; keep_releases : int
  }

val git_sha : unit -> (string, string) result

val make_up_request
  :  scope:string option
  -> dry_run:bool
  -> tag:string option
  -> confirm_group_change:bool
  -> keep_releases:int
  -> git_sha:(unit -> (string, string) result)
  -> (up_request, string) result

val make_deploy_request
  :  target:string
  -> scope:string option
  -> dry_run:bool
  -> emit_to:string option
  -> emit_plan_to:string option
  -> image_tag:string option
  -> image_refs:(string option * string) list
  -> registry:string option
  -> secret_backend:Sol_cli_manifest.secret_backend option
  -> confirm_group_change:bool
  -> loki_push_url:string option
  -> keep_releases:int
  -> git_sha:(unit -> (string, string) result)
  -> (deploy_request, string) result
