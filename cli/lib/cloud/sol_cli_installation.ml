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
  | Delegated_zone

let prerequisite_label = function
  | State_backend -> "terraform state backend"
  | State_lock -> "terraform state lock"
  | Provisioning_identity -> "provisioning identity"
  | Cluster_access_identity -> "cluster-access identity"
  | Deploy_identity -> "deploy identity"
  | Operator_identity -> "operator identity"
  | Delegated_zone -> "delegated DNS zone"
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
  ; named "operator identity" configuration.operator_identity
  ; named "zone domain" configuration.zone_domain
  ; named "project" configuration.project_id
  ]
;;

let require what = function
  | Some value when not (Sol_cli_string.is_blank value) -> Ok (String.trim value)
  | _ -> Error (Printf.sprintf "the installation requires %s" what)
;;

let declared_value = function
  | Some value when not (Sol_cli_string.is_blank value) -> Some (String.trim value)
  | _ -> None
;;

let declared target key = declared_value (Sol_cli_config.provider_field target key)

let of_target (target : Sol_cli_config.target) =
  let open Result.Syntax in
  let* state_bucket =
    require
      "the target's state_bucket: a Terraform root cannot create the backend that stores \
       its own state, so the backend is declared on the target and provisioned once by \
       the durable root"
      (declared_value target.state_bucket)
  in
  let* region = require "the target's region" (declared_value (Some target.region)) in
  Ok
    { state_bucket
    ; state_prefix =
        Printf.sprintf "bootstrap/%s" (Sol_cli_provider.to_string target.provider)
    ; region
    ; lock_table = declared target "state_lock_table"
    ; provisioning_identity = declared target "provisioner_role_arn"
    ; cluster_access_identity = declared target "cluster_access_role_arn"
    ; deploy_identity = declared target "deploy_role_arn"
    ; operator_identity = declared target "operator_role_arn"
    ; zone_domain = declared_value target.base_domain
    ; project_id = declared target "project_id"
    }
;;

type observation =
  | Observed of string
  | Absent of string
  | Unobservable of string

type probe =
  | Inspect of
      { prerequisite : prerequisite
      ; argv : string list
      ; classify : observation -> verdict
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
          | Observed _ -> Established
          | Absent refusal -> Unmet refusal
          | Unobservable reason -> Unknown reason)
    }
;;

let present_if_output_names
      ?(present = fun output -> not (Sol_cli_string.is_blank output))
      prerequisite
      ~reason
      argv
  =
  Inspect
    { prerequisite
    ; argv
    ; classify =
        (function
          | Observed output when present output -> Established
          | Observed _ -> Unmet reason
          | Absent refusal -> Unmet refusal
          | Unobservable why -> Unknown why)
    }
;;

let absent prerequisite reason = Unavailable { prerequisite; reason }

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
           | Unobservable reason, Established -> Unknown reason
           | _ -> verdict
         in
         probe.prerequisite, verdict)
    probes
;;
