type t = Production_single_region

let version Production_single_region = 1
let selection_name Production_single_region = "production-single-region"
let to_string t = Printf.sprintf "%s/v%d" (selection_name t) (version t)
let all = [ Production_single_region ]

let known_selections () =
  all |> List.map selection_name |> List.map (Printf.sprintf "%S") |> String.concat ", "
;;

let of_selection s =
  match List.find_opt (fun t -> selection_name t = s) all with
  | Some t -> Ok t
  | None ->
    Error
      (Printf.sprintf "unknown profile %S (known profiles: %s)" s (known_selections ()))
;;

let of_string s =
  match List.find_opt (fun t -> to_string t = s) all with
  | Some t -> Ok t
  | None -> Error (Printf.sprintf "unknown profile identity %S" s)
;;

type capability =
  | Qualified_substrate
  | Qualified_versions
  | Direct_apply_authority
  | Remote_state
  | Scoped_operator_identities
  | Alert_delivery
  | Immutable_artifacts
  | Credential_posture
  | Workload_availability
  | Postgres_durability
  | Kafka_durability

let capability_to_string = function
  | Qualified_substrate -> "qualified_substrate"
  | Qualified_versions -> "qualified_versions"
  | Direct_apply_authority -> "direct_apply_authority"
  | Remote_state -> "remote_state"
  | Scoped_operator_identities -> "scoped_operator_identities"
  | Alert_delivery -> "alert_delivery"
  | Immutable_artifacts -> "immutable_artifacts"
  | Credential_posture -> "credential_posture"
  | Workload_availability -> "workload_availability"
  | Postgres_durability -> "postgres_durability"
  | Kafka_durability -> "kafka_durability"
;;

let capability_description = function
  | Qualified_substrate -> "qualified provider/substrate"
  | Qualified_versions -> "qualified version set"
  | Direct_apply_authority -> "direct apply reconciliation authority"
  | Remote_state -> "recoverable remote infrastructure state"
  | Scoped_operator_identities -> "scoped operator identity"
  | Alert_delivery -> "alert delivery to an owner"
  | Immutable_artifacts -> "immutable artifact identity"
  | Credential_posture -> "workload credential posture"
  | Workload_availability -> "workload availability"
  | Postgres_durability -> "Postgres durability"
  | Kafka_durability -> "Kafka durability"
;;

type workload_capability =
  | Long_running
  | Postgres
  | Kafka

let guarantee_of_use = function
  | Long_running -> Workload_availability
  | Postgres -> Postgres_durability
  | Kafka -> Kafka_durability
;;

let requirements Production_single_region uses =
  [ Qualified_substrate
  ; Qualified_versions
  ; Direct_apply_authority
  ; Remote_state
  ; Scoped_operator_identities
  ; Alert_delivery
  ; Immutable_artifacts
  ; Credential_posture
  ]
  @ List.map guarantee_of_use (List.sort_uniq compare uses)
;;
