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

type resolved_configuration =
  { state_bucket : string
  ; state_prefix : string
  ; region : string
  ; lock_table : string option
  ; zone_domain : string option
  ; project_id : string option
  }

let resolved_configuration_to_lines configuration =
  let line label = function
    | None -> Printf.sprintf "  %-16s (none)" label
    | Some value -> Printf.sprintf "  %-16s %s" label value
  in
  [ Printf.sprintf "  %-16s %s" "state bucket" configuration.state_bucket
  ; Printf.sprintf "  %-16s %s" "state prefix" configuration.state_prefix
  ; Printf.sprintf "  %-16s %s" "region" configuration.region
  ; line "lock table" configuration.lock_table
  ; line "zone domain" configuration.zone_domain
  ; line "project" configuration.project_id
  ]
;;
