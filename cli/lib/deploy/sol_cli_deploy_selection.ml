open Result.Syntax

type selection =
  { resolved : Sol_cli_workload_selection.resolved
  ; image_refs : (string * string) list
  }

let select ~image_refs inventory =
  let* resolved =
    Sol_cli_workload_selection.resolve_nonempty
      ~none:"no services found in app/ with a Dockerfile"
      None
      inventory
  in
  let* image_refs =
    Sol_cli_image_ref.resolve
      ~service_names:
        (List.map (fun (s : Sol_cli_manifest.service) -> s.name) resolved.services)
      image_refs
  in
  Ok { resolved; image_refs }
;;

type deployed =
  { services : Sol_cli_manifest.service list
  ; notes : string list
  }

let unit_id (s : Sol_cli_manifest.service) = Printf.sprintf "%s/%s" s.domain s.name

let secret_authorities_for_plan ~config plan =
  let missing = ref [] in
  let mappings = ref [] in
  List.iter
    (fun (spec : Sol_cli_deployment_plan.service_spec) ->
       let unit_address = spec.domain ^ "/" ^ spec.source_name in
       let transport = Sol_cli_manifest.kafka_transport_of_config spec.config in
       let required =
         Sol_cli_manifest.required_secret_keys ~transport (List.map fst spec.secrets)
       in
       let resolution =
         Sol_cli_config.resolve_secret_authorities
           config.Sol_cli_config.target
           ~unit_address
           ~required_keys:required
       in
       List.iter
         (fun key -> missing := (unit_address, key) :: !missing)
         resolution.missing;
       List.iter
         (fun (key, authority) -> mappings := (unit_address, key, authority) :: !mappings)
         resolution.resolved)
    plan.Sol_cli_deployment_plan.services;
  match List.rev !missing with
  | (unit_address, key) :: _ ->
    Error
      (Printf.sprintf
         "target %s has no secret authority for %s/%s; declare it under \
          targets.<provider>/<region>.secrets in sol/environments.yml"
         config.Sol_cli_config.target.name
         unit_address
         key)
  | [] -> Ok (List.rev !mappings)
;;

let refuse_external_delivery ~config plan =
  let* mappings = secret_authorities_for_plan ~config plan in
  let external_keys =
    List.filter_map
      (fun (unit_address, key, authority) ->
         match authority with
         | Sol_cli_config.Sol_managed -> None
         | External _ -> Some (unit_address, key))
      mappings
  in
  match external_keys with
  | [] -> Ok ()
  | (unit_address, key) :: _ ->
    Error
      (Printf.sprintf
         "Cannot deploy %s.\n\n\
          %s is externally managed, but external secret delivery is not yet supported by \
          this deployment path. No legacy backend or placeholder will be used."
         config.Sol_cli_config.target.name
         (unit_address ^ "/" ^ key))
;;

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
  let notes =
    List.map
      (fun s ->
         Printf.sprintf
           "Note: %s is omitted by target %s, so it is excluded from this deploy."
           (unit_id s)
           target)
      omission.excluded
  in
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
           "--image-ref names %s, which target %s omits, so this whole-target deploy \
            excludes it. Drop the reference."
           s.name
           target)
  in
  match omission.selected with
  | [] ->
    Error
      (Printf.sprintf
         "target %s omits every service, so this whole-target deploy has nothing to \
          deploy: %s."
         target
         (String.concat ", " (List.map unit_id omission.excluded)))
  | services -> Ok { services; notes }
;;

type plan_error =
  | Refused of string
  | Preflight of Sol_cli_profile.t * Sol_cli_profile_preflight.finding list

module Planning_input = struct
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

module Target_plan_input = struct
  type t =
    { workspace : string
    ; registry : string
    ; sha : string
    ; emit_to : string option
    ; secret_backend : Sol_cli_manifest.secret_backend
    ; config : Sol_cli_config.t
    ; facts : Sol_cli_workspace_model.t
    ; inventory : Sol_cli_manifest.service list
    ; image_refs : (string * string) list
    ; services : Sol_cli_manifest.service list
    }
end

module Target_plan = struct
  type t = { deployment_plan : Sol_cli_deployment_plan.t }

  let profile t = t.deployment_plan.profile
  let to_deployment_plan t = t.deployment_plan
end

let plan (input : Planning_input.t) =
  let open Planning_input in
  let { workspace
      ; registry
      ; sha
      ; emit_to
      ; secret_backend
      ; config
      ; facts
      ; inventory
      ; requested_scope
      ; image_refs
      ; services
      }
    =
    input
  in
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
  let* _secret_mappings = secret_authorities_for_plan ~config plan |> refused in
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

let target_plan (input : Target_plan_input.t) =
  let open Target_plan_input in
  let { workspace
      ; registry
      ; sha
      ; emit_to
      ; secret_backend
      ; config
      ; facts
      ; inventory
      ; image_refs
      ; services
      }
    =
    input
  in
  plan
    { Planning_input.workspace
    ; registry
    ; sha
    ; emit_to
    ; secret_backend
    ; config
    ; facts
    ; inventory
    ; requested_scope = "workspace"
    ; image_refs
    ; services
    }
  |> Result.map (fun deployment_plan -> Target_plan.{ deployment_plan })
;;
