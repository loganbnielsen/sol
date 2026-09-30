type verdict =
  | Established
  | Unmet of string
  | Unknown of string

type prerequisite =
  | State_backend
  | State_lock
  | Provisioning_identity
  | Cluster_access_identity
  | Deploy_identity
  | Operator_identity
  | Publisher_identity
  | Delegated_zone

let prerequisite_label = function
  | State_backend -> "terraform state backend"
  | State_lock -> "terraform state lock"
  | Provisioning_identity -> "provisioning identity"
  | Cluster_access_identity -> "cluster-access identity"
  | Deploy_identity -> "deploy identity"
  | Operator_identity -> "operator identity"
  | Publisher_identity -> "publisher identity"
  | Delegated_zone -> "delegated DNS zone"
;;

let prerequisites = function
  | Sol_cli_provider.Aws ->
    [ State_backend
    ; State_lock
    ; Provisioning_identity
    ; Cluster_access_identity
    ; Deploy_identity
    ; Operator_identity
    ; Publisher_identity
    ; Delegated_zone
    ]
  | Sol_cli_provider.Gcp ->
    [ State_backend
    ; Provisioning_identity
    ; Cluster_access_identity
    ; Deploy_identity
    ; Operator_identity
    ; Delegated_zone
    ]
;;

let verdict_label = function
  | Established -> "Established"
  | Unmet reason -> "Unmet: " ^ reason
  | Unknown reason -> "UNKNOWN: " ^ reason
;;

let establish = Established
let unmet reason = Unmet reason
let unknown reason = Unknown reason

let unresolved verdicts =
  List.filter
    (fun (_, verdict) ->
       match verdict with
       | Established -> false
       | Unmet _ | Unknown _ -> true)
    verdicts
;;

let all_established verdicts =
  match unresolved verdicts with
  | [] -> Ok ()
  | (prerequisite, verdict) :: _ ->
    Error
      (Printf.sprintf
         "%s is %s"
         (prerequisite_label prerequisite)
         (verdict_label verdict))
;;

let summary verdicts =
  String.concat
    "\n"
    (List.map
       (fun (prerequisite, verdict) ->
          Printf.sprintf
            "  %-28s %s"
            (prerequisite_label prerequisite)
            (verdict_label verdict))
       verdicts)
;;

type installation_config =
  { state_bucket : string
  ; state_prefix : string
  ; region : string
  ; lock_table : string option
  ; provisioning_identity : string option
  ; cluster_access_identity : string option
  ; deploy_identity : string option
  ; publisher_identity : string option
  ; operator_identity : string option
  ; zone_domain : string option
  ; project_id : string option
  }

let resolved_configuration_to_lines configuration =
  let named label = function
    | None -> Printf.sprintf "  %-24s (none)" label
    | Some value -> Printf.sprintf "  %-24s %s" label value
  in
  [ Printf.sprintf "  %-24s %s" "state bucket" configuration.state_bucket
  ; Printf.sprintf "  %-24s %s" "state prefix" configuration.state_prefix
  ; Printf.sprintf "  %-24s %s" "region" configuration.region
  ; named "lock table" configuration.lock_table
  ; named "provisioning identity" configuration.provisioning_identity
  ; named "cluster-access identity" configuration.cluster_access_identity
  ; named "deploy identity" configuration.deploy_identity
  ; named "publisher identity" configuration.publisher_identity
  ; named "operator identity" configuration.operator_identity
  ; named "zone domain" configuration.zone_domain
  ; named "project" configuration.project_id
  ]
;;

type probe =
  | Inspect of
      { prerequisite : prerequisite
      ; argv : string list
      ; classify : string option -> verdict
      }
  | Unavailable of
      { prerequisite : prerequisite
      ; reason : string
      }

let probe_prerequisite = function
  | Inspect probe -> probe.prerequisite
  | Unavailable probe -> probe.prerequisite
;;

let present_if_output prerequisite argv =
  Inspect
    { prerequisite
    ; argv
    ; classify =
        (function
          | Some _ -> Established
          | None -> Unknown "the probe could not be run")
    }
;;

let absent prerequisite reason = Unavailable { prerequisite; reason }

let probes provider configuration =
  let role prerequisite name =
    match name with
    | Some name ->
      present_if_output prerequisite [ "aws"; "iam"; "get-role"; "--role-name"; name ]
    | None ->
      absent
        prerequisite
        (Printf.sprintf
           "the resolved installation configuration names no %s"
           (prerequisite_label prerequisite))
  in
  let service_account prerequisite name =
    match name with
    | Some name ->
      present_if_output
        prerequisite
        [ "gcloud"; "iam"; "service-accounts"; "describe"; name; "--format=value(email)" ]
    | None ->
      absent
        prerequisite
        (Printf.sprintf
           "the resolved installation configuration names no %s"
           (prerequisite_label prerequisite))
  in
  match provider with
  | Sol_cli_provider.Aws ->
    [ present_if_output
        State_backend
        [ "aws"
        ; "s3api"
        ; "head-bucket"
        ; "--bucket"
        ; configuration.state_bucket
        ; "--region"
        ; configuration.region
        ]
    ; (match configuration.lock_table with
       | Some table ->
         present_if_output
           State_lock
           [ "aws"
           ; "dynamodb"
           ; "describe-table"
           ; "--table-name"
           ; table
           ; "--region"
           ; configuration.region
           ]
       | None ->
         absent
           State_lock
           "the resolved installation configuration names no lock table, and the AWS \
            durable root declares one")
    ; role Provisioning_identity configuration.provisioning_identity
    ; role Cluster_access_identity configuration.cluster_access_identity
    ; role Deploy_identity configuration.deploy_identity
    ; role Operator_identity configuration.operator_identity
    ; role Publisher_identity configuration.publisher_identity
    ; (match configuration.zone_domain with
       | Some domain ->
         present_if_output
           Delegated_zone
           [ "aws"; "route53"; "list-hosted-zones-by-name"; "--dns-name"; domain ]
       | None -> absent Delegated_zone "this installation owns no delegated DNS zone")
    ]
  | Sol_cli_provider.Gcp ->
    [ present_if_output
        State_backend
        [ "gcloud"
        ; "storage"
        ; "buckets"
        ; "describe"
        ; Printf.sprintf "gs://%s" configuration.state_bucket
        ; "--format=value(name)"
        ]
    ; service_account Provisioning_identity configuration.provisioning_identity
    ; service_account Cluster_access_identity configuration.cluster_access_identity
    ; service_account Deploy_identity configuration.deploy_identity
    ; service_account Operator_identity configuration.operator_identity
    ; (match configuration.zone_domain with
       | Some domain ->
         present_if_output
           Delegated_zone
           [ "gcloud"
           ; "dns"
           ; "managed-zones"
           ; "describe"
           ; domain
           ; "--format=value(name)"
           ]
       | None -> absent Delegated_zone "this installation owns no delegated DNS zone")
    ]
;;

let observe ~run probes =
  List.map
    (fun probe ->
       match probe with
       | Unavailable probe -> probe.prerequisite, Unmet probe.reason
       | Inspect probe ->
         let observed = run probe.argv in
         let verdict = probe.classify observed in
         let verdict =
           match observed, verdict with
           | None, Established ->
             Unknown "the probe could not be run, so nothing was observed"
           | _ -> verdict
         in
         probe.prerequisite, verdict)
    probes
;;
