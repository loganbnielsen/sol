type observation =
  { quota_name : string
  ; limit_gb : int
  ; used_gb : int
  }

let governing_quota = "SSD_TOTAL_GB"
let free_gb observation = observation.limit_gb - observation.used_gb

let observation_of_json ?(quota = governing_quota) json : (observation, string) result =
  let open Result.Syntax in
  let what = quota in
  let* parsed = Sol_cli_json.decode ~what json in
  let quotas =
    Sol_cli_json.field [ "quotas" ] parsed
    |> Sol_cli_json.list
    |> Option.value ~default:[]
  in
  let metric entry = Sol_cli_json.field [ "metric" ] entry |> Sol_cli_json.string in
  match List.find_opt (fun entry -> metric entry = Some quota) quotas with
  | None ->
    Error
      (Printf.sprintf
         "the region reports no %s: the quota that governs %s is not present in this \
          provider's response, so Sol cannot say whether the platform's volumes fit"
         quota
         "the platform's storage class")
  | Some entry ->
    let gb name =
      Sol_cli_json.require ~what [ name ] Sol_cli_json.float entry
      |> Result.map int_of_float
    in
    let* limit_gb = gb "limit" in
    let* used_gb = gb "usage" in
    Ok { quota_name = quota; limit_gb; used_gb }
;;

let describe observation =
  Printf.sprintf
    "%s %d/%d GiB used (%d GiB free)"
    observation.quota_name
    observation.used_gb
    observation.limit_gb
    (free_gb observation)
;;

let sufficient ~observation ~required_gb : (unit, string) result =
  if free_gb observation >= required_gb
  then Ok ()
  else
    Error
      (Printf.sprintf
         "the provider has no room for the platform's volumes: %s, and the platform's \
          declared minimum persistent-disk requirement is %d GiB. The cluster's own \
          footprint is already in the observed usage (that is why this is checked after \
          the cloud infrastructure is up); Sol's volumes are not, because none exists \
          yet. Raise the project's %s quota, or lower what the platform asks for."
         (describe observation)
         required_gb
         observation.quota_name)
;;
