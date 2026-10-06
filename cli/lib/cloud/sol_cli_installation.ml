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
  | Public_delegation

type zone_ownership =
  | Sol_created
  | User_supplied
  | Externally_delegated

let zone_ownership_label = function
  | Sol_created ->
    "sol-created (durable: Sol creates it and only an explicit uninstall removes it)"
  | User_supplied -> "user-supplied (Sol never removes it)"
  | Externally_delegated ->
    "externally delegated (the parent is yours; Sol asks for the delegation, it does not \
     own the zone)"
;;

let zone_ownership_of_declaration = function
  | Some "sol" -> Ok Sol_created
  | Some "user" -> Ok User_supplied
  | Some "external" -> Ok Externally_delegated
  | Some other ->
    Error
      (Printf.sprintf
         "the target declares dns_zone_ownership %S; the accepted values are sol (the \
          installation creates and owns the zone), user (you created it, and Sol never \
          removes it) and external (the zone is published outside Sol and delegated to \
          this installation)"
         other)
  | None ->
    Error
      "the target declares no dns_zone_ownership: say who owns the zone, because the \
       three cases behave differently — sol (the installation creates and owns it), user \
       (you created it, and Sol never removes it) or external (published elsewhere and \
       delegated to this installation). Sol will not guess a zone's owner from the fact \
       that a zone exists"
;;

let zone_ownership_declaration = function
  | Sol_created -> "sol"
  | User_supplied -> "user"
  | Externally_delegated -> "external"
;;

let prerequisite_label = function
  | State_backend -> "terraform state backend"
  | State_lock -> "terraform state lock"
  | Provisioning_identity -> "provisioning identity"
  | Cluster_access_identity -> "cluster-access identity"
  | Deploy_identity -> "deploy identity"
  | Operator_identity -> "operator identity"
  | Delegated_zone -> "delegated DNS zone"
  | Public_delegation -> "public delegation"
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

let health_summary verdicts =
  let reason_of = function
    | Established -> "established"
    | Unmet reason | Unknown reason -> reason
  in
  match unresolved verdicts with
  | [] -> "Healthy"
  | unresolved ->
    let headline =
      match
        List.find_opt
          (fun (_, verdict) ->
             match verdict with
             | Unknown _ -> true
             | Established | Unmet _ -> false)
          unresolved
      with
      | Some _ -> "Unknown"
      | None -> "Unmet"
    in
    Printf.sprintf
      "%s — %s"
      headline
      (String.concat
         "; "
         (List.map
            (fun (prerequisite, verdict) ->
               prerequisite_label prerequisite ^ ": " ^ reason_of verdict)
            unresolved))
;;

type zone =
  | No_zone
  | Service_zone of
      { domain : string
      ; ownership : zone_ownership
      }

type installation_config =
  { state_bucket : string
  ; state_prefix : string
  ; region : string
  ; lock_table : string option
  ; provisioning_identity : string option
  ; cluster_access_identity : string option
  ; deploy_identity : string option
  ; operator_identity : string option
  ; zone : zone
  ; project_id : string option
  }

let zone_domain = function
  | No_zone -> None
  | Service_zone zone -> Some zone.domain
;;

let owns_the_zone = function
  | Service_zone { ownership = Sol_created; _ } -> true
  | No_zone | Service_zone _ -> false
;;

let address_in_zone ~zone address =
  String.equal address zone || String.starts_with ~prefix:(zone ^ "[") address
;;

(* A provider answers with the fully qualified DNS name, which carries the
   root's trailing dot, while the declared domain is written without one; DNS
   names are also case-insensitive. Normalizing both is what lets a lookup be
   decided by the zone's name rather than by the position the provider put it
   in. *)
let normalized_dns_name name =
  let name = String.trim name in
  let name =
    if String.length name > 0 && name.[String.length name - 1] = '.'
    then String.sub name 0 (String.length name - 1)
    else name
  in
  String.lowercase_ascii name
;;

let dns_names_equal left right =
  String.equal (normalized_dns_name left) (normalized_dns_name right)
;;

(* [select_zone_identity ~domain candidates] picks the identity of the one zone
   named exactly [domain]. Providers list zones by name prefix (Route53's
   ListHostedZonesByName returns the next zone when the requested name is
   absent), so a response can hold the request's descendants -- including, for
   the parent lookup, the installation's own zone -- and those must never be
   read as the zone that was asked for. [Ok None] is positively-established
   absence; more than one exact match is an error, because Sol will not guess
   which zone the installation already owns. *)
let select_zone_identity ~domain candidates =
  let matches = List.filter (fun (_, name) -> dns_names_equal domain name) candidates in
  match matches with
  | [] -> Ok None
  | [ (identity, _) ] -> Ok (Some identity)
  | _ ->
    Error
      (Printf.sprintf
         "%d zones are named exactly %s, and Sol will not guess which one this \
          installation already owns"
         (List.length matches)
         domain)
;;

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
  ; named "zone domain" (zone_domain configuration.zone)
  ; Printf.sprintf
      "  %-24s %s"
      "zone ownership"
      (match configuration.zone with
       | No_zone -> "(none: this target serves no domain)"
       | Service_zone zone -> zone_ownership_label zone.ownership)
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
  let* zone =
    match declared_value target.base_domain with
    | None -> Ok No_zone
    | Some domain ->
      let* ownership =
        zone_ownership_of_declaration (declared_value target.dns_zone_ownership)
      in
      Ok (Service_zone { domain; ownership })
  in
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
    ; zone
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
  | Unverifiable of
      { prerequisite : prerequisite
      ; reason : string
      }

let probe_prerequisite = function
  | Inspect probe -> probe.prerequisite
  | Unavailable probe -> probe.prerequisite
  | Unverifiable probe -> probe.prerequisite
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
let unverifiable prerequisite reason = Unverifiable { prerequisite; reason }

let observe ~run probes =
  List.map
    (fun probe ->
       match probe with
       | Unavailable probe -> probe.prerequisite, Unmet probe.reason
       | Unverifiable probe -> probe.prerequisite, Unknown probe.reason
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
