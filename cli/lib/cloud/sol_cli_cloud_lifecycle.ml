let backend_config (target : Sol_cli_config.target) ~root =
  let layer =
    match root with
    | `Cloud -> "cloud"
    | `Platform -> "platform"
    | `Authorization -> "authorization"
  in
  let object_key = Printf.sprintf "sol/%s/%s.tfstate" target.name layer in
  match target.state_bucket with
  | Some bucket ->
    (Sol_cli_provider_capabilities.capabilities_of target.provider).backend_config
      target
      ~bucket
      ~object_key
  | None ->
    Error "target must declare state_bucket before `sol cloud` can use durable state"
;;

let authorization_backend target = backend_config target ~root:`Authorization

type cloud_target =
  { target : Sol_cli_config.target
  ; cloud_backend : string list
  ; platform_backend : string list
  ; base_domain : string
  ; letsencrypt_email : string
  ; cluster_access_role_arn : string option
  }

let required = Sol_cli_provider_capabilities.required

let cloud_target target =
  let open Result.Syntax in
  let* cloud_backend = backend_config target ~root:`Cloud in
  let* platform_backend = backend_config target ~root:`Platform in
  let* base_domain = required "base_domain" target.base_domain in
  let* letsencrypt_email = required "letsencrypt_email" target.letsencrypt_email in
  let* cluster_access_role_arn =
    (Sol_cli_provider_capabilities.capabilities_of target.provider)
      .cluster_access_role_arn
      target
  in
  Ok
    { target
    ; cloud_backend
    ; platform_backend
    ; base_domain
    ; letsencrypt_email
    ; cluster_access_role_arn
    }
;;

let platform_address address = "module.platform." ^ address
let target config = config.target
let cloud_backend config = config.cloud_backend
let platform_backend config = config.platform_backend

type platform_inputs =
  { base_domain : string
  ; letsencrypt_email : string
  ; region : string
  ; cluster_issuer : string option
  ; observability_backend : string option
  ; alert_receiver_type : string option
  ; alert_receiver_url : string option
  ; alert_owner : string option
  ; alert_runbook_url : string option
  ; cluster : Sol_cli_cluster.t
  }

let platform_inputs (target : cloud_target) (cluster : Sol_cli_cluster.t) =
  match
    cluster.check_identity ~cluster_access_role_arn:target.cluster_access_role_arn
  with
  | Error _ as refused -> refused
  | Ok () ->
    Ok
      { base_domain = target.base_domain
      ; letsencrypt_email = target.letsencrypt_email
      ; region = target.target.region
      ; cluster_issuer = target.target.cluster_issuer
      ; observability_backend = target.target.observability_backend
      ; alert_receiver_type = target.target.alert_receiver_type
      ; alert_receiver_url = target.target.alert_receiver_url
      ; alert_owner = target.target.alert_owner
      ; alert_runbook_url = target.target.alert_runbook_url
      ; cluster
      }
;;

type failure_policy =
  | Continue_to_destroy
  | Block_destroy

type 'a preparation_outcome =
  | Nothing_to_prepare
  | Prepared of 'a
  | Preparation_failed of
      { reason : string
      ; policy : failure_policy
      }

let preparation_failure = function
  | Nothing_to_prepare | Prepared _ -> None
  | Preparation_failed { reason; _ } -> Some reason
;;

let destruction_blocked = function
  | Nothing_to_prepare | Prepared _ -> None
  | Preparation_failed { policy = Continue_to_destroy; _ } -> None
  | Preparation_failed { reason; policy = Block_destroy } -> Some reason
;;

let preparations_eligible ~state ~desired =
  List.filter (fun address -> List.mem address state) desired
;;

let preparations_unrepresented ~state ~desired =
  List.filter (fun address -> not (List.mem address state)) desired
;;

type platform_vars_context = Sol_cli_cluster.platform_vars_context =
  | Install
  | Destruction

let platform_terraform_vars ?(context = Install) inputs =
  let add_opt key value vars =
    match value with
    | None -> vars
    | Some value -> (key ^ "=" ^ value) :: vars
  in
  let optional vars =
    vars
    |> add_opt "cluster_issuer" inputs.cluster_issuer
    |> add_opt "observability_backend" inputs.observability_backend
    |> add_opt "alert_receiver_type" inputs.alert_receiver_type
    |> add_opt "alert_receiver_url" inputs.alert_receiver_url
    |> add_opt "alert_owner" inputs.alert_owner
    |> add_opt "alert_runbook_url" inputs.alert_runbook_url
  in
  let shared =
    [ "base_domain=" ^ inputs.base_domain
    ; "letsencrypt_email=" ^ inputs.letsencrypt_email
    ; "install_postgresql=false"
    ]
  in
  Result.map
    (fun { Sol_cli_cluster.fixed; optional = provider_optional } ->
       List.fold_left
         (fun vars (key, value) -> add_opt key value vars)
         (optional (shared @ fixed))
         provider_optional)
    (inputs.cluster.platform_vars
       context
       ~cluster_issuer:inputs.cluster_issuer
       ~region:inputs.region)
;;

type plan_phase =
  | Plannable
  | Deferred of string

let platform_plan_phases ~cluster_exists ~rbac_established ~crds_established =
  let requires_cloud = "requires cloud substrate to exist" in
  let requires_rbac =
    "requires provisioner platform RBAC established by an earlier apply"
  in
  if not cluster_exists
  then Deferred requires_cloud, Deferred requires_cloud
  else if not rbac_established
  then Deferred requires_rbac, Deferred requires_rbac
  else if not crds_established
  then Plannable, Deferred "requires cert-manager CRDs to be Established"
  else Plannable, Plannable
;;

type authorization =
  | Required
  | Forbidden

let provisioner_authorization_checks =
  [ Required, [ "create"; "deployments.apps"; "-n"; "monitoring" ]
  ; Required, [ "create"; "services"; "-n"; "ingress-nginx" ]
  ; Required, [ "create"; "customresourcedefinitions.apiextensions.k8s.io" ]
  ; Required, [ "create"; "storageclasses.storage.k8s.io" ]
  ; Required, [ "create"; "clusterissuers.cert-manager.io" ]
  ; Required, [ "create"; "namespaces" ]
  ; Forbidden, [ "create"; "deployments.apps"; "-n"; "default" ]
  ; Forbidden, [ "create"; "services"; "-n"; "default" ]
  ; Forbidden, [ "create"; "jobs.batch"; "-n"; "default" ]
  ; Forbidden, [ "create"; "secrets"; "-n"; "default" ]
  ; Forbidden, [ "bind"; "clusterroles.rbac.authorization.k8s.io" ]
  ; Forbidden, [ "escalate"; "clusterroles.rbac.authorization.k8s.io" ]
  ]
;;

let provisioner_authorization_established ~can_i =
  provisioner_authorization_checks
  |> List.for_all (fun (expected, args) ->
    match expected with
    | Required -> can_i args
    | Forbidden -> not (can_i args))
;;

type readiness =
  | Established
  | Unmet of string

type readiness_check =
  { name : string
  ; reason : string
  ; accept : string -> bool
  ; argv : string list
  }

let check ?(accept = fun _ -> true) name reason argv = { name; reason; accept; argv }

let available_deployments namespace =
  [ "wait"
  ; "--for=condition=Available"
  ; "deployment"
  ; "--all"
  ; "-n"
  ; namespace
  ; "--timeout=5s"
  ]
;;

let converged_workload ~kind ~namespace ~ready_field ~desired_field =
  [ "get"
  ; kind
  ; "-n"
  ; namespace
  ; "-o"
  ; Printf.sprintf
      "jsonpath={range .items[*]}{.%s}/{.%s}{' '}{end}"
      ready_field
      desired_field
  ]
;;

let converged_daemonsets namespace =
  converged_workload
    ~kind:"daemonset"
    ~namespace
    ~ready_field:"status.numberReady"
    ~desired_field:"status.desiredNumberScheduled"
;;

let converged_statefulsets namespace =
  converged_workload
    ~kind:"statefulset"
    ~namespace
    ~ready_field:"status.readyReplicas"
    ~desired_field:"status.replicas"
;;

let bound_pvcs namespace =
  [ "get"
  ; "pvc"
  ; "-n"
  ; namespace
  ; "-o"
  ; "jsonpath={range .items[*]}{.status.phase}{' '}{end}"
  ]
;;

let ready_nodes =
  [ "get"
  ; "nodes"
  ; "-o"
  ; "jsonpath={range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}{' \
     '}{end}"
  ]
;;

let replicas_converged ?(require_desired = true) output =
  let pairs =
    String.split_on_char ' ' (String.trim output) |> List.filter (fun part -> part <> "")
  in
  pairs <> []
  && pairs
     |> List.for_all (fun pair ->
       match String.split_on_char '/' pair with
       | [ ready; desired ] ->
         (match int_of_string_opt ready, int_of_string_opt desired with
          | Some ready, Some desired ->
            ready = desired && (desired > 0 || not require_desired)
          | None, _ | _, None -> false)
       | _ -> false)
;;

let daemonsets_converged output = replicas_converged output
let statefulsets_converged output = replicas_converged ~require_desired:false output

let all_pvcs_bound output =
  let phases =
    String.split_on_char ' ' (String.trim output) |> List.filter (fun part -> part <> "")
  in
  phases <> [] && List.for_all (fun phase -> phase = "Bound") phases
;;

let all_nodes_ready output =
  let states =
    String.split_on_char ' ' (String.trim output) |> List.filter (fun part -> part <> "")
  in
  states <> [] && List.for_all (fun state -> state = "True") states
;;

type platform_storage = Sol_cli_provider_capabilities.platform_storage =
  { storage_class : string
  ; csi_driver : string
  }

let platform_storage provider =
  (Sol_cli_provider_capabilities.capabilities_of provider).platform_storage
;;

let storage_class_entries =
  let jsonpath =
    "jsonpath={range .items[*]}"
    ^ "{.metadata.name}{'|'}{.provisioner}{'|'}"
    ^ "{.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class}"
    ^ "{' '}{end}"
  in
  [ "get"; "storageclass"; "-o"; jsonpath ]
;;

let sole_default_storage_class ~storage_class ~csi_driver output =
  let fields entry = String.split_on_char '|' entry in
  let is_default entry =
    match fields entry with
    | [ _; _; "true" ] -> true
    | _ -> false
  in
  match String.split_on_char ' ' (String.trim output) |> List.filter is_default with
  | [ entry ] ->
    (match fields entry with
     | [ name; provisioner; _ ] -> name = storage_class && provisioner = csi_driver
     | _ -> false)
  | [] | _ :: _ :: _ -> false
;;

let storage_checks provider =
  let { storage_class; csi_driver } = platform_storage provider in
  [ check
      ~accept:(sole_default_storage_class ~storage_class ~csi_driver)
      "default StorageClass"
      (Printf.sprintf
         "%s is absent, is not the only default StorageClass, or is not provided by %s"
         storage_class
         csi_driver)
      storage_class_entries
  ; check
      "block-storage CSI driver"
      (Printf.sprintf "the %s block-storage CSI driver is not registered" csi_driver)
      [ "get"; "csidriver/" ^ csi_driver ]
  ]
;;

let platform_certificate_checks =
  List.map
    (fun (declared : Sol_cli_platform_tls.declared_certificate) ->
       check
         (Printf.sprintf "platform certificate %s" declared.certificate)
         (Printf.sprintf
            "the platform's declared certificate %s/%s is not Ready, so the platform \
             cannot             serve the TLS it declares (DEC-056); an unpublished \
             delegation or a failing ACME             challenge is the usual reason"
            declared.namespace
            declared.certificate)
         [ "wait"
         ; "--for=condition=Ready"
         ; "certificate/" ^ declared.certificate
         ; "-n"
         ; declared.namespace
         ; "--timeout=5s"
         ])
    Sol_cli_platform_tls.certificates
;;

let readiness_checks ~provider =
  let before_storage =
    [ check
        "cert-manager CRDs"
        "required cert-manager CRDs are not Established"
        [ "wait"
        ; "--for=condition=Established"
        ; "crd/certificates.cert-manager.io"
        ; "crd/clusterissuers.cert-manager.io"
        ; "--timeout=5s"
        ]
    ; check
        "cert-manager controllers"
        "cert-manager controller, webhook, or cainjector is unavailable"
        (available_deployments "cert-manager")
    ; check ~accept:all_nodes_ready "nodes" "a cluster node is not Ready" ready_nodes
    ]
  in
  before_storage
  @ storage_checks provider
  @ [ check
        "monitoring deployments"
        "a monitoring deployment is not available"
        (available_deployments "monitoring")
    ; check
        ~accept:statefulsets_converged
        "monitoring statefulsets"
        "a monitoring statefulset does not have every declared replica ready"
        (converged_statefulsets "monitoring")
    ; check
        ~accept:daemonsets_converged
        "monitoring daemonsets"
        "a monitoring daemonset does not have every scheduled pod ready"
        (converged_daemonsets "monitoring")
    ; check
        ~accept:all_pvcs_bound
        "monitoring PVCs"
        "a monitoring PersistentVolumeClaim is not Bound"
        (bound_pvcs "monitoring")
    ; check
        "Redpanda"
        "Redpanda broker-native cluster health is not healthy"
        [ "exec"
        ; "-n"
        ; "redpanda"
        ; "statefulset/redpanda"
        ; "--"
        ; "rpk"
        ; "cluster"
        ; "health"
        ; "--exit-when-healthy"
        ; "--watch=false"
        ]
    ; check
        ~accept:statefulsets_converged
        "Redpanda statefulset"
        "the Redpanda statefulset does not have every declared replica ready"
        (converged_statefulsets "redpanda")
    ; check
        ~accept:all_pvcs_bound
        "Redpanda PVCs"
        "a Redpanda PersistentVolumeClaim is not Bound"
        (bound_pvcs "redpanda")
    ; check
        "ingress-nginx"
        "ingress-nginx controller is unavailable"
        (available_deployments "ingress-nginx")
    ; check
        ~accept:(fun output -> output <> "")
        "ingress endpoint"
        "ingress-nginx LoadBalancer has no assigned endpoint"
        [ "get"
        ; "service/ingress-nginx-controller"
        ; "-n"
        ; "ingress-nginx"
        ; "-o"
        ; "jsonpath={.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}"
        ]
    ; check
        "Argo CD"
        "an Argo CD controller is unavailable"
        (available_deployments "argocd")
    ]
  @ platform_certificate_checks
;;

let readiness ~provider ~run =
  readiness_checks ~provider
  |> List.map (fun check ->
    ( check.name
    , match run check.argv with
      | Some output when check.accept (String.trim output) -> Established
      | _ -> Unmet check.reason ))
;;

let readiness_invocations ~provider =
  List.map (fun check -> check.name, check.argv) (readiness_checks ~provider)
;;

let readiness_summary checks =
  match
    checks
    |> List.filter_map (fun (name, result) ->
      match result with
      | Established -> None
      | Unmet reason -> Some (name ^ ": " ^ reason))
  with
  | [] -> "Ready"
  | unmet -> "Unmet — " ^ String.concat "; " unmet
;;

type phase =
  | Absent
  | Cloud_bootstrap
  | Platform_installing
  | Ready
  | Platform_updating
  | Preparing_destroy
  | Destroying

type phase_policy =
  | Bootstrap
  | Installation
  | Production
  | Destroy

let policy_of_phase = function
  | Absent | Cloud_bootstrap -> Bootstrap
  | Platform_installing | Platform_updating -> Installation
  | Ready -> Production
  | Preparing_destroy | Destroying -> Destroy
;;

let transition_allowed ~from ~to_ =
  match from, to_ with
  | Absent, Cloud_bootstrap -> true
  | Cloud_bootstrap, Platform_installing -> true
  | Platform_installing, Ready -> true
  | Ready, Platform_updating -> true
  | Platform_updating, Ready -> true
  | Ready, Preparing_destroy -> true
  | Preparing_destroy, Destroying -> true
  | Destroying, Absent -> true
  | _ -> false
;;

let destruction_available = function
  | Absent -> false
  | Cloud_bootstrap
  | Platform_installing
  | Ready
  | Platform_updating
  | Preparing_destroy
  | Destroying -> true
;;

let enter_destruction ~from =
  if destruction_available from then Preparing_destroy else Absent
;;

let ready_policy_applies phase = policy_of_phase phase = Production

type destroy_retention =
  | Retain_final_snapshot
  | Retain_nothing

let default_destroy_retention = Retain_final_snapshot

let destroy_retention_to_string = function
  | Retain_final_snapshot -> "final-snapshot"
  | Retain_nothing -> "none"
;;

let destroy_retention_of_string = function
  | "final-snapshot" -> Ok Retain_final_snapshot
  | "none" -> Ok Retain_nothing
  | other ->
    Error
      (Printf.sprintf
         "unknown destroy_retention %S (expected \"final-snapshot\" or \"none\")"
         other)
;;

let policy_vars ~provider ~phase ~destroy_snapshot_id ~retention =
  match policy_of_phase phase with
  | Bootstrap | Installation | Production -> []
  | Destroy ->
    (Sol_cli_provider_capabilities.capabilities_of provider).destroy_guard_vars
      ~final_snapshot:
        (match retention with
         | Retain_final_snapshot -> Some destroy_snapshot_id
         | Retain_nothing -> None)
;;

let phase_to_string = function
  | Absent -> "Absent"
  | Cloud_bootstrap -> "CloudBootstrap"
  | Platform_installing -> "PlatformInstalling"
  | Ready -> "Ready"
  | Platform_updating -> "PlatformUpdating"
  | Preparing_destroy -> "PreparingDestroy"
  | Destroying -> "Destroying"
;;

let observed_phase ~cloud_exists ~platform_installed =
  if not cloud_exists
  then Absent
  else if platform_installed
  then Ready
  else Platform_installing
;;

type deescalation_principal =
  | Principal_confirmed of string
  | Principal_refused_by_cluster of string
  | Principal_probe_failed of string
  | Principal_unexpected of string

type deescalation_verdict =
  | Deescalated
  | Still_elevated of string list
  | Undetermined of string

type capability_answer =
  | Permitted
  | Denied
  | Indeterminate of string

let first_token text =
  let text = String.trim text in
  let line_end =
    match String.index_opt text '\n' with
    | Some i -> i
    | None -> String.length text
  in
  let rec scan i =
    if i >= line_end
    then i
    else (
      match text.[i] with
      | ' ' | '\t' | '\r' -> i
      | _ -> scan (i + 1))
  in
  String.sub text 0 (scan 0)
;;

let capability_answer_of_can_i_output ~exit_code ~stdout ~stderr =
  let describe () =
    let text = String.trim (stderr ^ " " ^ stdout) in
    if String.equal text ""
    then Printf.sprintf "kubectl exited %d with no output" exit_code
    else Printf.sprintf "kubectl exited %d (%s)" exit_code text
  in
  match first_token stdout with
  | "yes" when exit_code = 0 -> Permitted
  | "no" when exit_code = 1 -> Denied
  | "yes" | "no" ->
    Indeterminate
      (Printf.sprintf
         "kubectl answered %S but exited %d; a mismatch is not an answer"
         (first_token stdout)
         exit_code)
  | _ -> Indeterminate (describe ())
;;

type capability =
  { verb : string
  ; resource : string
  }

let capability_label { verb; resource } = Printf.sprintf "%s %s" verb resource

let answer_is_permitted = function
  | Permitted -> true
  | Denied | Indeterminate _ -> false
;;

let indeterminate_reason (capability, answer) =
  match answer with
  | Indeterminate why -> Some (capability_label capability, why)
  | Permitted | Denied -> None
;;

let permitted_capabilities probes =
  probes
  |> List.filter_map (fun (capability, answer) ->
    if answer_is_permitted answer then Some capability else None)
;;

let still_permitted probes = List.map capability_label (permitted_capabilities probes)

let deescalation_verdict
      ~(principal : deescalation_principal)
      (probes : (capability * capability_answer) list)
  : deescalation_verdict
  =
  match principal with
  | Principal_unexpected who ->
    Undetermined
      (Printf.sprintf
         "the probe answered as %s, not the principal whose elevation was removed"
         who)
  | Principal_probe_failed why -> Undetermined why
  | Principal_refused_by_cluster _why -> Deescalated
  | Principal_confirmed _ ->
    let still = still_permitted probes in
    if still <> []
    then Still_elevated still
    else (
      match List.find_map indeterminate_reason probes with
      | Some (capability, why) ->
        Undetermined
          (Printf.sprintf
             "the capability probe for %s obtained no usable answer (%s), so the \
              effective surface is not established"
             capability
             why)
      | None ->
        if probes = []
        then Undetermined "no capability probe produced an answer"
        else Deescalated)
;;

let successor_authority (successor : (capability * capability_answer) list) =
  let unmet =
    successor
    |> List.filter_map (fun (capability, answer) ->
      match answer with
      | Permitted -> None
      | Denied -> Some (Printf.sprintf "%s is denied" (capability_label capability))
      | Indeterminate why ->
        Some
          (Printf.sprintf
             "%s obtained no usable answer (%s)"
             (capability_label capability)
             why))
  in
  if successor = []
  then
    Error
      "no successor capability was probed, so the successor's authority is not \
       established"
  else if unmet <> []
  then Error (String.concat "; " unmet)
  else Ok ()
;;

let deescalation_transition
      ~(before : (capability * capability_answer) list)
      ~after_principal
      ~(after : (capability * capability_answer) list)
  =
  match after_principal with
  | Principal_unexpected who ->
    Undetermined
      (Printf.sprintf
         "the principal answering after de-escalation was %s, not the one observed \
          during the window; the transition is not established"
         who)
  | Principal_probe_failed why ->
    Undetermined ("the post-de-escalation probe obtained no evidence: " ^ why)
  | Principal_refused_by_cluster _ -> Deescalated
  | Principal_confirmed _ ->
    let still = still_permitted after in
    if still <> []
    then Still_elevated still
    else (
      match List.find_map indeterminate_reason after with
      | Some (capability, why) ->
        Undetermined
          (Printf.sprintf
             "the capability probe for %s obtained no usable answer after de-escalation \
              (%s), so removal is not established"
             capability
             why)
      | None ->
        let before_permitted = permitted_capabilities before in
        let uncovered =
          before_permitted
          |> List.filter (fun capability -> not (List.mem_assoc capability after))
        in
        if uncovered <> []
        then
          Undetermined
            (Printf.sprintf
               "the post-de-escalation probe did not cover %s, so its removal is not \
                established"
               (String.concat ", " (List.map capability_label uncovered)))
        else (
          match List.find_map indeterminate_reason before with
          | Some (capability, why) ->
            Undetermined
              (Printf.sprintf
                 "the bootstrap window probe for %s obtained no usable answer (%s), so \
                  its later removal cannot be demonstrated"
                 capability
                 why)
          | None ->
            if before_permitted = []
            then
              Undetermined
                "the bootstrap-only capabilities were never observed permitted, so no \
                 removal can be demonstrated"
            else Deescalated))
;;

let deescalation_verdict_to_string = function
  | Deescalated ->
    "de-escalated: the effective surface no longer permits bootstrap capabilities"
  | Still_elevated capabilities ->
    Printf.sprintf
      "still elevated: the de-escalated identity is still permitted %s"
      (String.concat ", " capabilities)
  | Undetermined why -> Printf.sprintf "undetermined: %s" why
;;

let enter ~from ~to_ =
  if transition_allowed ~from ~to_
  then Ok to_
  else
    Error
      (Printf.sprintf
         "illegal lifecycle transition %s -> %s"
         (phase_to_string from)
         (phase_to_string to_))
;;
