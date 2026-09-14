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
  ; confirm_group_change : bool
  ; keep_releases : int
  }

type deploy_request =
  { target : string
  ; scope : string option
  ; action : deploy_action
  ; emit_plan_to : string option
  ; image_tag : string
  ; registry : string option
  ; secret_backend : Sol_cli_manifest.secret_backend
  ; confirm_group_change : bool
  ; loki_push_url : string option
  ; keep_releases : int
  }

let make_up_request ~scope ~dry_run ~tag ~confirm_group_change ~keep_releases ~git_sha =
  if keep_releases < 1
  then
    Error
      "keep-releases must be at least 1 (the current and previous release are always \
       kept)"
  else (
    let image_tag =
      match tag with
      | Some t -> t
      | None -> git_sha ()
    in
    let mode = if dry_run then Dry_run else Apply in
    Ok { scope; mode; image_tag; confirm_group_change; keep_releases })
;;

let make_deploy_request
      ~target
      ~scope
      ~dry_run
      ~emit_to
      ~emit_plan_to
      ~image_tag
      ~registry
      ~secret_backend
      ~confirm_group_change
      ~loki_push_url
      ~keep_releases
      ~git_sha
  =
  if String.length (String.trim target) = 0
  then Error "target must not be empty (expected <env>/<provider>/<region>)"
  else if keep_releases < 1
  then
    Error
      "keep-releases must be at least 1 (the current and previous release are always \
       kept)"
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
      ; scope
      ; action
      ; emit_plan_to
      ; image_tag
      ; registry
      ; secret_backend
      ; confirm_group_change
      ; loki_push_url
      ; keep_releases
      })
;;
