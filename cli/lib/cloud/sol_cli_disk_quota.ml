(* INFRA-090 / FND-0062: the provider's own disk-quota reading, and whether what it leaves
   free covers the volumes the platform declares it needs.

   The division of knowledge here is deliberate, because FND-0062 was a failure of exactly
   that division:

     - the *limit* and the *usage* are provider observations. This module reads them and
       invents nothing;
     - the *requirement* is Sol's own declaration ({!Sol_cli_platform_storage});
     - the *comparison* is Sol's lifecycle policy ({!sufficient});
     - how many nodes the provider will create and how large their boot disks are is
       provider-owned, and is deliberately **not** modelled. Attempt 12 showed why: the
       footprint is whatever the cluster happens to have made by the time we look, and
       Attempt 12's cluster had already spent the entire quota on itself before the platform
       asked for a single volume. Predicting it would mean reproducing Autopilot's
       scheduling and autoscaling behaviour, which is not Sol's to know. *)

type observation =
  { quota_name : string
    (** The provider's own name for the quota, quoted back so a log says which one was read *)
  ; limit_gb : int
  ; used_gb : int
  }

(* GKE's `standard-rwo` -- the class Sol establishes as the platform's default -- is backed by
   `pd-balanced` disks, and Compute charges those against SSD_TOTAL_GB. That is not a guess:
   it is the quota the provider named when it refused Attempt 12's volumes, verbatim
   `CreateVolume failed ... (QUOTA_EXCEEDED): Quota 'SSD...'`, while the region reported
   `SSD_TOTAL_GB limit=500.0 usage=500.0`. `DISKS_TOTAL_GB` is the separate quota that
   governs standard (pd-standard) disks, which Sol does not ask for. *)
let governing_quota = "SSD_TOTAL_GB"
let free_gb observation = observation.limit_gb - observation.used_gb

(* Read one quota out of a `gcloud compute regions describe <region> --format=json` payload.
   A quota that is not in the payload is an error, never a zero: "the region does not report
   this quota" and "the region has none of it left" are different facts, and only one of them
   is safe to read as "not enough". *)
let observation_of_json ?(quota = governing_quota) json : (observation, string) result =
  let open Yojson.Safe.Util in
  match Yojson.Safe.from_string json with
  | exception Yojson.Json_error message ->
    Error (Printf.sprintf "%s is not JSON: %s" quota message)
  | parsed ->
    let quotas =
      try member "quotas" parsed |> to_list with
      | Type_error _ -> []
    in
    let metric entry =
      try member "metric" entry |> to_string with
      | Type_error _ -> ""
    in
    (match List.find_opt (fun entry -> String.equal (metric entry) quota) quotas with
     | None ->
       Error
         (Printf.sprintf
            "the region reports no %s: the quota that governs %s is not present in this \
             provider's response, so Sol cannot say whether the platform's volumes fit"
            quota
            "the platform's storage class")
     | Some entry ->
       let int_of member_name =
         match member member_name entry with
         | `Float value -> int_of_float value
         | `Int value -> value
         | `Intlit value -> int_of_string value
         | _ -> 0
         | exception Type_error _ -> 0
       in
       Ok { quota_name = quota; limit_gb = int_of "limit"; used_gb = int_of "usage" })
;;

let describe observation =
  Printf.sprintf
    "%s %d/%d GiB used (%d GiB free)"
    observation.quota_name
    observation.used_gb
    observation.limit_gb
    (free_gb observation)
;;

(* Sol's lifecycle policy: observed availability against Sol's declared minimum. The message
   names all three numbers and where each came from, so a refusal needs no further reading. *)
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
