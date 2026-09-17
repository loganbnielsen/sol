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
let establish ~(target : Sol_cli_config.target) ~apply_mode capability =
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
  | Qualified_versions
  | Remote_state
  | Scoped_operator_identities
  | Alert_delivery
  | Immutable_artifacts
  | Credential_posture
  | Workload_availability
  | Postgres_durability
  | Kafka_durability -> not_yet_established
;;

let check ?establish:establish_opt ~target ~apply_mode (plan : Sol_cli_deployment_plan.t) =
  match plan.profile with
  | None -> Ok ()
  | Some (claim : Sol_cli_deployment_plan.profile_claim) ->
    let establish = Option.value establish_opt ~default:(establish ~target ~apply_mode) in
    let findings =
      List.filter_map
        (fun capability ->
           match establish capability with
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
