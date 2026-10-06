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

let qualified_providers =
  Sol_cli_provider.all
  |> List.filter (fun provider ->
    (Sol_cli_provider_capabilities.capabilities_of provider).production_qualified)
;;

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
    let images =
      plan.services
      |> List.map (fun (spec : Sol_cli_deployment_plan.service_spec) -> spec.image)
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
    (match
       Sol_cli_alerting.validate
         ~receiver_type:target.alert_receiver_type
         ~receiver_url:target.alert_receiver_url
         ~owner:target.alert_owner
         ~runbook_url:target.alert_runbook_url
     with
     | Ok () -> Established
     | Error reason -> Unmet (Target, reason))
  | Credential_posture -> Established
  | Qualified_versions ->
    let profile =
      match plan.profile with
      | Some claim -> claim.profile
      | None -> Sol_cli_profile.Production_single_region
    in
    let services = plan.services in
    let unstated =
      services
      |> List.filter (fun (s : Sol_cli_deployment_plan.service_spec) -> s.language = None)
    in
    let unsupported =
      services
      |> List.filter_map (fun (s : Sol_cli_deployment_plan.service_spec) ->
        match s.language with
        | Some language when not (Sol_cli_compat.is_supported_by_profile profile language)
          -> Some (s.source_name, language)
        | _ -> None)
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
    let capabilities = Sol_cli_provider_capabilities.capabilities_of target.provider in
    let declared = Option.is_some in
    let locked =
      match capabilities.state_locking with
      | None -> true
      | Some key -> declared (Sol_cli_config.provider_field target key)
    in
    if declared target.state_bucket && locked
    then Established
    else
      Unmet
        ( Target
        , Printf.sprintf
            "declare an encrypted, versioned remote Terraform state backend with \
             locking: set `state_bucket`%s (Sol provisions a conformant one via \
             `platform/cloud/aws/bootstrap`)"
            (match capabilities.state_locking with
             | Some key ->
               Printf.sprintf
                 " and `%s.%s`"
                 (Sol_cli_provider.to_string target.provider)
                 key
             | None -> "") )
  | Scoped_operator_identities ->
    let present = Option.is_some in
    let missing_roles =
      List.filter_map
        (fun (name, value) -> if present value then None else Some name)
        (List.map
           (fun key ->
              ( Sol_cli_provider.to_string target.provider ^ "." ^ key
              , Sol_cli_config.provider_field target key ))
           (Sol_cli_provider_capabilities.capabilities_of target.provider)
             .scoped_identities)
    in
    let cidr =
      match target.cluster_endpoint_cidr with
      | Some "0.0.0.0/0" ->
        Error
          "`cluster_endpoint_cidr` is 0.0.0.0/0; a production target must restrict the \
           public Kubernetes API endpoint to a specific CIDR"
      | Some c -> Ok c
      | None ->
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
  | Workload_availability ->
    let required =
      List.length
        (plan.services
         |> List.filter (fun (s : Sol_cli_deployment_plan.service_spec) ->
           Sol_cli_availability.is_node_failure_tolerant s.availability))
    in
    if required = 0
    then Established
    else (
      match target.node_failure_headroom_nodes with
      | Some declared when declared >= required -> Established
      | Some declared ->
        Unmet
          ( Target
          , Printf.sprintf
              "`node_failure_headroom_nodes` is %d but %d node-failure-tolerant \
               workload(s) each need one spare node's capacity; raise it to at least %d \
               (DEC-026 §3)"
              declared
              required
              required )
      | None ->
        Unmet
          ( Target
          , Printf.sprintf
              "declare `node_failure_headroom_nodes` >= %d: %d node-failure-tolerant \
               workload(s) need one spare node's capacity each so a lost node's replicas \
               can be restored (DEC-026 §3)"
              required
              required ))
  | Postgres_durability ->
    if List.mem target.provider qualified_providers
    then Established
    else
      Unmet
        ( Target
        , Printf.sprintf
            "provider %s does not implement this profile's Postgres durability \
             configuration (profile-derived Multi-AZ, encrypted storage, 7-day PITR \
             window); qualified: %s"
            (Sol_cli_provider.to_string target.provider)
            (qualified_providers
             |> List.map Sol_cli_provider.to_string
             |> String.concat ", ") )
  | Kafka_durability ->
    let consumers =
      plan.services
      |> List.filter (fun (s : Sol_cli_deployment_plan.service_spec) -> s.consumes_kafka)
    in
    let missing =
      consumers
      |> List.filter (fun (s : Sol_cli_deployment_plan.service_spec) ->
        not (List.mem_assoc "SOL_KAFKA_DURABILITY" s.config))
    in
    if not (List.mem target.provider qualified_providers)
    then
      Unmet
        ( Target
        , Printf.sprintf
            "provider %s does not implement this profile's qualified Kafka durability \
             path (RF >= 3, acks=all, write caching disabled); qualified: %s"
            (Sol_cli_provider.to_string target.provider)
            (qualified_providers
             |> List.map Sol_cli_provider.to_string
             |> String.concat ", ") )
    else (
      match missing with
      | first :: _ ->
        Unmet
          ( Application
          , Printf.sprintf
              "Kafka-consuming workload %S is not rendered with the qualified durability \
               requirement (SOL_KAFKA_DURABILITY); a workload that reads or writes Kafka \
               under this profile must carry it"
              first.source_name )
      | [] -> Established)
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
      claim.requirements
      |> List.filter_map (fun capability ->
        match
          Option.value (application_status capability) ~default:(establish capability)
        with
        | Established -> None
        | Unmet (side, reason) -> Some { capability; side; reason })
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
