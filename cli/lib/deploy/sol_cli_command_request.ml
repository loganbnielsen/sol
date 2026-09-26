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
    (** FEAT-050: raw [--image-ref] values, already validated as digest
          references but not yet resolved against the selected services (that
          happens in [cmd_deploy.ml] once the scope is known). Each entry is
          [Some service, ref] for [<service>=<ref>] or [None, ref] for a bare
          reference. *)
  ; registry : string option
  ; secret_backend : Sol_cli_manifest.secret_backend option
    (** INFRA-050: [None] means the operator did not choose, so the resolved
          *destination* decides ({!Sol_cli_env_target.default_secret_backend}:
          live for a direct/local deploy, placeholder for GitOps). The CLI must
          not carry a default of its own -- two defaults meant a direct deploy
          emitted an empty Secret and the workload could not start. *)
  ; confirm_group_change : bool
  ; loki_push_url : string option
  ; keep_releases : int
  }

(* BUG-058: the commit an image built from this checkout is tagged with. An
   error carries git's own reason; there is no sentinel tag. *)
let git_sha () =
  match
    Sol_cli_process.run (Sol_cli_process.cmd [ "git"; "rev-parse"; "--short"; "HEAD" ])
  with
  | Ok { exit_code = 0; stdout; _ } when String.trim stdout <> "" ->
    Ok (String.trim stdout)
  | Ok { exit_code; stderr; _ } ->
    let reason = String.trim stderr in
    Error
      (if reason = "" then Printf.sprintf "git rev-parse exited %d" exit_code else reason)
  | Error e -> Error (Sol_cli_process.error_to_string e)
;;

let local_fallback_tag = "dev"

let make_up_request ~scope ~dry_run ~tag ~confirm_group_change ~keep_releases ~git_sha =
  if keep_releases < 1
  then
    Error
      "keep-releases must be at least 1 (the current and previous release are always \
       kept)"
  else (
    (* A local cluster may fall back to a fixed tag, but says so. *)
    let image_tag, image_tag_warning =
      match tag with
      | Some t -> t, None
      | None ->
        (match git_sha () with
         | Ok sha -> sha, None
         | Error reason ->
           ( local_fallback_tag
           , Some
               (Printf.sprintf
                  "could not resolve the git commit for the image tag (%s); tagging \
                   images %S. Pass --image-tag to choose a tag."
                  reason
                  local_fallback_tag) ))
    in
    let mode = if dry_run then Dry_run else Apply in
    Ok { scope; mode; image_tag; image_tag_warning; confirm_group_change; keep_releases })
;;

let invalid_image_ref refs =
  List.find_opt (fun (_, ref) -> not (Sol_cli_image_ref.is_digest ref)) refs
;;

let make_deploy_request
      ~target
      ~scope
      ~dry_run
      ~emit_to
      ~emit_plan_to
      ~image_tag
      ~image_refs
      ~registry
      ~secret_backend
      ~confirm_group_change
      ~loki_push_url
      ~keep_releases
      ~git_sha
  =
  match invalid_image_ref image_refs with
  | Some (_, bad) ->
    Error
      (Printf.sprintf
         "--image-ref %S is not an immutable reference; expected <repo>@sha256:<64 \
          hexadecimal digits>"
         bad)
  | None ->
    if String.length (String.trim target) = 0
    then Error "target must not be empty (expected <env>/<provider>/<region>)"
    else if keep_releases < 1
    then
      Error
        "keep-releases must be at least 1 (the current and previous release are always \
         kept)"
    else (
      (* BUG-058: a deploy never falls back to a shared, mutable tag. *)
      let image_tag =
        match image_tag with
        | Some t -> Ok t
        | None ->
          Result.map_error
            (fun reason ->
               Printf.sprintf
                 "could not resolve the git commit to tag images with (%s); pass \
                  --image-tag <tag> to deploy"
                 reason)
            (git_sha ())
      in
      match image_tag with
      | Error _ as e -> e
      | Ok image_tag ->
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
          ; image_refs
          ; registry
          ; secret_backend
          ; confirm_group_change
          ; loki_push_url
          ; keep_releases
          })
;;
