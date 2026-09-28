open Result.Syntax

type selection =
  { requested_scope : string
  ; resolved : Sol_cli_workload_selection.resolved
  ; image_refs : (string * string) list
  }

let select ~scope ~image_refs inventory =
  let* resolved =
    Sol_cli_workload_selection.resolve_nonempty
      ~none:"no services found in app/ with a Dockerfile"
      scope
      inventory
  in
  let* image_refs =
    Sol_cli_image_ref.resolve
      ~service_names:
        (List.map (fun (s : Sol_cli_manifest.service) -> s.name) resolved.services)
      image_refs
  in
  Ok { requested_scope = resolved.requested_scope; resolved; image_refs }
;;

type deployed =
  { services : Sol_cli_manifest.service list
  ; notes : string list
  }

let unit_id (s : Sol_cli_manifest.service) = Printf.sprintf "%s/%s" s.domain s.name

let apply_target ~target ~(config : Sol_cli_config.t) selection =
  let* () =
    if Sol_cli_config.target_declared config.target
    then Ok ()
    else
      Error
        (Printf.sprintf
           "target %S is not declared in %s -- sol deploy requires an explicit target, \
            even an empty one, so a typo'd or unintended target can't silently inherit \
            sol.yml's shared defaults and deploy anyway."
           target
           (Sol_cli_config.target_source config.target))
  in
  let omission =
    Sol_cli_workload_selection.apply_omission
      ~is_omitted:(fun s -> Sol_cli_config.is_omitted_service config ~name:s.name)
      selection.resolved
  in
  let inclusion_notes =
    List.map
      (fun s ->
         Printf.sprintf
           "Note: %s is omitted by target %s, and --scope named it, so it is included."
           (unit_id s)
           target)
      omission.included
  in
  let exclusion_notes =
    List.map
      (fun s ->
         Printf.sprintf
           "Note: %s is omitted by target %s, so it is excluded from this deploy."
           (unit_id s)
           target)
      omission.excluded
  in
  let notes = inclusion_notes @ exclusion_notes in
  let* () =
    match
      selection.image_refs
      |> List.find_map (fun (name, _) ->
        omission.excluded
        |> List.find_opt (fun (s : Sol_cli_manifest.service) -> String.equal s.name name))
    with
    | None -> Ok ()
    | Some s ->
      Error
        (Printf.sprintf
           "--image-ref names %s, which target %s omits and this deploy excludes. Name \
            it with --scope %s to deploy it, or drop the reference."
           s.name
           target
           (unit_id s))
  in
  match omission.selected with
  | [] ->
    Error
      (Printf.sprintf
         "every unit in scope is omitted by target %s: %s.\n\
         \  Name one with --scope <domain>/<name> to deploy it anyway."
         target
         (String.concat ", " (List.map unit_id omission.excluded)))
  | services -> Ok { services; notes }
;;

type plan_error =
  | Refused of string
  | Preflight of Sol_cli_profile.t * Sol_cli_profile_preflight.finding list

let plan
      ~workspace
      ~registry
      ~sha
      ~emit_to
      ~secret_backend
      ~(config : Sol_cli_config.t)
      ~facts
      ~inventory
      ~requested_scope
      ~image_refs
      services
  =
  let refused r = Result.map_error (fun m -> Refused m) r in
  let* env_target =
    Sol_cli_env_target.customer_cloud_defaults ~registry ~image_tag:sha ~emit_to ()
    |> refused
  in
  let* () =
    match env_target, secret_backend with
    | Sol_cli_env_target.Customer_gitops _, Sol_cli_manifest.Kubernetes_live ->
      Error
        (Refused
           "cannot use --secret-backend kubernetes-live with --emit-to (GitOps mode).\n\
           \  This combination would write plaintext secrets into the GitOps repository,\n\
           \  leaking them to every reader of the repo.\n\
           \  Use --secret-backend kubernetes-placeholder (the default) or \
            --secret-backend external-secrets instead.")
    | _ -> Ok ()
  in
  let env =
    { (Sol_cli_env_target.to_env_config ~name:workspace env_target) with
      Sol_cli_deployment_plan.secret_backend
    ; env = Some config.target.env
    ; cluster_issuer =
        Option.value config.target.cluster_issuer ~default:"letsencrypt-prod"
    }
  in
  let* plan =
    Sol_cli_factory.plan_of_services
      ~workspace
      ~env
      ~facts
      ~requested_scope
      ~declared:(Sol_cli_config.declared_of_config config)
      ~image_refs
      ~inventory
      services
    |> refused
  in
  let apply_mode =
    match emit_to with
    | Some _ -> Sol_cli_release.Gitops
    | None -> Sol_cli_release.Direct
  in
  let* () =
    Sol_cli_profile_preflight.check ~target:config.target ~apply_mode plan
    |> Result.map_error (fun (profile, findings) -> Preflight (profile, findings))
  in
  Ok plan
;;
