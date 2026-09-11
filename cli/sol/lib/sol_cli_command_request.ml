type execution_mode =
  | Dry_run
  | Apply

type deploy_action =
  | Deploy_dry_run of { emit_to : string option }
  | Deploy_emit_to of string
  | Deploy_apply

type up_request =
  { filter_path : string option
  ; mode : execution_mode
  ; image_tag : string
  ; confirm_group_change : bool
  }

type deploy_request =
  { target : string
  ; filter_path : string option
  ; action : deploy_action
  ; emit_plan_to : string option
  ; image_tag : string
  ; registry : string option
  ; secret_backend : Sol_cli_manifest.secret_backend
  ; confirm_group_change : bool
  ; loki_push_url : string option
  }

let make_up_request ~filter_path ~dry_run ~tag ~confirm_group_change ~git_sha =
  let image_tag =
    match tag with
    | Some t -> t
    | None -> git_sha ()
  in
  let mode = if dry_run then Dry_run else Apply in
  Ok { filter_path; mode; image_tag; confirm_group_change }
;;

let make_deploy_request
      ~target
      ~filter_path
      ~dry_run
      ~emit_to
      ~emit_plan_to
      ~image_tag
      ~registry
      ~secret_backend
      ~confirm_group_change
      ~loki_push_url
      ~git_sha
  =
  if String.length (String.trim target) = 0
  then Error "target must not be empty (expected <env>/<provider>/<region>)"
  else (
    let image_tag =
      match image_tag with
      | Some t -> t
      | None -> git_sha ()
    in
    let action =
      if dry_run
      then Deploy_dry_run { emit_to }
      else (
        match emit_to with
        | Some dir -> Deploy_emit_to dir
        | None -> Deploy_apply)
    in
    Ok
      { target
      ; filter_path
      ; action
      ; emit_plan_to
      ; image_tag
      ; registry
      ; secret_backend
      ; confirm_group_change
      ; loki_push_url
      })
;;
