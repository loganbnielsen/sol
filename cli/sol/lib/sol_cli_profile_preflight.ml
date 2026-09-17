type side =
  | Application
  | Target
  | Platform

type status =
  | Established
  | Unmet of side * string

type finding =
  { capability : Sol_cli_profile.capability
  ; side : side
  ; reason : string
  }

let qualified_providers = [ Sol_cli_provider.Aws ]

let not_yet_established =
  Unmet (Platform, "Sol cannot establish this guarantee for any target yet")
;;

(* Each [not_yet_established] branch is replaced by a real check as the
   production program implements that guarantee; none may be relaxed to pass
   before it can be established. *)
let establish
      ~(target : Sol_cli_config.target)
      ~apply_mode
      ~(plan : Sol_cli_deployment_plan.t)
      capability
  =
  match (capability : Sol_cli_profile.capability) with
  | Qualified_substrate ->
    if List.mem target.provider qualified_providers
    then Established
    else
      Unmet
        ( Target
        , Printf.sprintf
            "provider %s is not qualified for this profile (qualified: %s)"
            (Sol_cli_provider.to_string target.provider)
            (qualified_providers
             |> List.map Sol_cli_provider.to_string
             |> String.concat ", ") )
  | Direct_apply_authority ->
    (match (apply_mode : Sol_cli_release.apply_mode) with
     | Direct -> Established
     | Gitops ->
       Unmet
         ( Target
         , "--emit-to hands reconciliation to a GitOps controller; this profile requires \
            Sol's direct apply" ))
  | Immutable_artifacts ->
    (* FEAT-050: a tag can move under a recorded release, so the profile accepts
       only content digests. This is the application's choice of reference, not
       a property of the target. *)
    let images =
      List.map
        (fun (spec : Sol_cli_deployment_plan.service_spec) -> spec.image)
        plan.Sol_cli_deployment_plan.services
    in
    if Sol_cli_image_ref.plan_is_immutable images
    then Established
    else
      Unmet
        ( Application
        , "every workload must deploy an immutable reference; pass --image-ref \
           <service>=<repo>@sha256:<digest> (or a single --image-ref \
           <repo>@sha256:<digest> with a one-service scope) instead of a mutable tag" )
  | Alert_delivery ->
    (* OBS-043: the receiver, owner and runbook are target declarations. Preflight
       asserts the declaration is complete and syntactically routable; delivered-
       and-acknowledged evidence is HARDEN-002's. *)
    (match
       Sol_cli_alerting.validate
         ~receiver_type:target.alert_receiver_type
         ~receiver_url:target.alert_receiver_url
         ~owner:target.alert_owner
         ~runbook_url:target.alert_runbook_url
     with
     | Ok () -> Established
     | Error reason -> Unmet (Target, reason))
  | Credential_posture ->
    (* SEC-004: the renderer disables ServiceAccount token automount for every
       workload it generates (Sol_cli_manifest_yaml.service_account_doc), so no
       plan can contain a workload with an ambient Kubernetes credential. This is
       a Sol-owned property of the rendered plan, not a target or application
       choice. Runtime secret rotation is the command-level behaviour of
       `sol secret set` (in-place update + verified restart), proven end-to-end by
       HARDEN-002. *)
    Established
  | Qualified_versions ->
    (* FEAT-088: the enforceable compatibility input is the declared framework
       language. Every workload must state one, and the profile must qualify it;
       nothing is inferred from build metadata (DEC-022 §7). The pinned
       CLI/substrate/chart versions are recorded in
       docs/deployment/compatibility.md. *)
    let profile =
      match plan.Sol_cli_deployment_plan.profile with
      | Some claim -> claim.profile
      | None -> Sol_cli_profile.Production_single_region
    in
    let services = plan.Sol_cli_deployment_plan.services in
    let unstated =
      List.filter
        (fun (s : Sol_cli_deployment_plan.service_spec) -> s.language = None)
        services
    in
    let unsupported =
      List.filter_map
        (fun (s : Sol_cli_deployment_plan.service_spec) ->
           match s.language with
           | Some language
             when not (Sol_cli_compat.is_supported_by_profile profile language) ->
             Some (s.source_name, language)
           | _ -> None)
        services
    in
    (match unstated, unsupported with
     | [], [] -> Established
     | first :: _, _ ->
       Unmet
         ( Application
         , Printf.sprintf
             "service %S does not declare a language; add `language: ocaml` (or \
              `typescript`) to its entry in sol.yml"
             first.source_name )
     | [], (name, language) :: _ ->
       Unmet
         ( Application
         , Printf.sprintf
             "service %S declares language %s, which %s does not qualify; the first \
              profile is OCaml-only (DEC-026 §2)"
             name
             (Sol_cli_compat.to_string language)
             (Sol_cli_profile.to_string profile) ))
  | Remote_state ->
    (* AUDIT-072: control state must be encrypted, versioned and locked, and a
       local backend is never conformant. Sol provisions a conformant backend by
       default (cli/platform/infra/bootstrap); an operator may bring their own by
       declaring it. Preflight asserts the declaration; the destructive recovery
       and concurrency checks are HARDEN-002's. *)
    (match target.state_bucket, target.state_lock_table with
     | Some bucket, Some lock when String.trim bucket <> "" && String.trim lock <> "" ->
       Established
     | _ ->
       Unmet
         ( Target
         , "declare an encrypted, versioned remote Terraform state backend with locking: \
            set `state_bucket` and `state_lock_table` (Sol provisions a conformant one \
            via `cli/platform/infra/bootstrap`)" ))
  | Scoped_operator_identities ->
    (* AUDIT-072: named provisioning/deploy/operator identities, distinct from
       the cluster-creator admin, plus an explicitly restricted public endpoint.
       Sol generates the least-privilege policy contracts; the operator supplies
       the role ARNs. *)
    let present = function
      | Some s -> String.trim s <> ""
      | None -> false
    in
    let missing_roles =
      List.filter_map
        (fun (name, value) -> if present value then None else Some name)
        [ "provisioner_role_arn", target.provisioner_role_arn
        ; "deploy_role_arn", target.deploy_role_arn
        ; "operator_role_arn", target.operator_role_arn
        ]
    in
    let cidr =
      match target.cluster_endpoint_cidr with
      | Some c when String.trim c = "0.0.0.0/0" ->
        Error
          "`cluster_endpoint_cidr` is 0.0.0.0/0; a production target must restrict the \
           public Kubernetes API endpoint to a specific CIDR"
      | Some c when String.trim c <> "" -> Ok (String.trim c)
      | _ ->
        Error
          "`cluster_endpoint_cidr` is missing; declare the one CIDR allowed to reach the \
           public Kubernetes API endpoint"
    in
    (match missing_roles with
     | _ :: _ ->
       Unmet
         ( Target
         , Printf.sprintf
             "declare the named identities distinct from the cluster-creator admin: %s \
              (Sol generates the least-privilege policy contracts; supply the role ARNs)"
             (String.concat ", " missing_roles) )
     | [] ->
       (match cidr with
        | Ok _ -> Established
        | Error reason -> Unmet (Target, reason)))
  | Workload_availability | Postgres_durability | Kafka_durability -> not_yet_established
;;

let check ?establish:establish_opt ~target ~apply_mode (plan : Sol_cli_deployment_plan.t) =
  match plan.profile with
  | None -> Ok ()
  | Some (claim : Sol_cli_deployment_plan.profile_claim) ->
    let establish =
      Option.value establish_opt ~default:(establish ~target ~apply_mode ~plan)
    in
    let application_status capability =
      match List.assoc_opt capability claim.application_findings with
      | Some reason -> Some (Unmet (Application, reason))
      | None -> None
    in
    let findings =
      List.filter_map
        (fun capability ->
           match
             Option.value (application_status capability) ~default:(establish capability)
           with
           | Established -> None
           | Unmet (side, reason) -> Some { capability; side; reason })
        claim.requirements
    in
    if findings = [] then Ok () else Error (claim.profile, findings)
;;

let side_to_string = function
  | Application -> "application"
  | Target -> "target"
  | Platform -> "sol"
;;

let finding_to_string f =
  Printf.sprintf
    "%s is not established [%s]: %s"
    (Sol_cli_profile.capability_description f.capability)
    (side_to_string f.side)
    f.reason
;;

let report profile findings =
  Printf.sprintf
    "error: this target selects profile %s, and preflight found %d unmet guarantee(s). \
     Nothing was changed.\n\
     %s\n"
    (Sol_cli_profile.to_string profile)
    (List.length findings)
    (findings |> List.map (fun f -> "  - " ^ finding_to_string f) |> String.concat "\n")
;;
