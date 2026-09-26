(* INFRA-090 / FND-0062: the disk-quota observation and the policy that reads it.

   The payloads here are the provider's own, taken from the Attempt 12 bundle: the region
   reported SSD_TOTAL_GB limit=500, usage=500 while five Autopilot nodes' boot disks were the
   entire consumption, and the CSI driver's refusal named the same quota. What this test pins is
   that Sol reads that number, refuses with the numbers in hand, and never turns "the provider
   did not report this quota" into "there is none of it". *)

let contains haystack needle =
  let n = String.length needle
  and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  n = 0 || at 0
;;

(* `gcloud compute regions describe us-central1 --format=json`, trimmed to what matters. *)
let attempt_12_payload =
  {|{"name":"us-central1","quotas":[
      {"metric":"CPUS","limit":200.0,"usage":22.0},
      {"metric":"DISKS_TOTAL_GB","limit":4096.0,"usage":0.0},
      {"metric":"SSD_TOTAL_GB","limit":500.0,"usage":500.0}]}|}
;;

let test_reads_the_governing_quota () =
  match Sol_cli_disk_quota.observation_of_json attempt_12_payload with
  | Error message -> Alcotest.failf "expected the quota to be read: %s" message
  | Ok observation ->
    Alcotest.(check string)
      "names the quota it read"
      "SSD_TOTAL_GB"
      observation.quota_name;
    Alcotest.(check int) "limit" 500 observation.limit_gb;
    Alcotest.(check int) "usage" 500 observation.used_gb;
    Alcotest.(check int) "free" 0 (Sol_cli_disk_quota.free_gb observation)
;;

let test_a_quota_the_region_does_not_report_is_not_zero () =
  let payload = {|{"quotas":[{"metric":"CPUS","limit":200.0,"usage":22.0}]}|} in
  match Sol_cli_disk_quota.observation_of_json payload with
  | Ok observation ->
    Alcotest.failf
      "an unreported quota became an observation: %s"
      (Sol_cli_disk_quota.describe observation)
  | Error message ->
    Alcotest.(check bool)
      "the refusal says the quota was not reported"
      true
      (contains message "reports no")
;;

let test_unparseable_payload_is_an_error () =
  match Sol_cli_disk_quota.observation_of_json "not json" with
  | Ok _ -> Alcotest.fail "an unparseable payload became an observation"
  | Error _ -> ()
;;

let test_sufficiency_is_the_declared_minimum () =
  let observation =
    { Sol_cli_disk_quota.quota_name = "SSD_TOTAL_GB"; limit_gb = 520; used_gb = 500 }
  in
  (* exactly enough is enough *)
  Alcotest.(check bool)
    "exactly the minimum passes"
    true
    (Result.is_ok (Sol_cli_disk_quota.sufficient ~observation ~required_gb:20));
  let thin =
    { Sol_cli_disk_quota.quota_name = "SSD_TOTAL_GB"; limit_gb = 519; used_gb = 500 }
  in
  match Sol_cli_disk_quota.sufficient ~observation:thin ~required_gb:20 with
  | Ok () -> Alcotest.fail "one GiB short passed"
  | Error message ->
    Alcotest.(check bool) "names the quota" true (contains message "SSD_TOTAL_GB");
    Alcotest.(check bool) "names the observation" true (contains message "500/519");
    Alcotest.(check bool) "names the requirement" true (contains message "20 GiB")
;;

let test_empty_quota_refuses_with_the_observed_numbers () =
  match Sol_cli_disk_quota.observation_of_json attempt_12_payload with
  | Error message -> Alcotest.failf "expected the quota to be read: %s" message
  | Ok observation ->
    (match
       Sol_cli_disk_quota.sufficient
         ~observation
         ~required_gb:Sol_cli_platform_storage.minimum_gb
     with
     | Ok () -> Alcotest.fail "a fully spent quota passed"
     | Error message ->
       Alcotest.(check bool) "names the observation" true (contains message "500/500");
       Alcotest.(check string)
         "agrees with Sol's own declaration"
         "20"
         (string_of_int Sol_cli_platform_storage.minimum_gb))
;;

(* The declaration is Sol's, and every part of it says where the number came from -- the CI
   guard cross-checks the parts against the Terraform declarations; this keeps the shape
   honest offline. *)
let test_the_declaration_is_described () =
  Alcotest.(check bool)
    "a minimum is declared"
    true
    (Sol_cli_platform_storage.minimum_gb > 0);
  Alcotest.(check bool)
    "every part carries its provenance"
    true
    (List.for_all
       (fun (part : Sol_cli_platform_storage.part) ->
          String.trim part.component <> ""
          && String.trim part.provenance <> ""
          && part.gib > 0)
       Sol_cli_platform_storage.parts);
  Alcotest.(check bool)
    "and the parts are what the minimum sums"
    true
    (Sol_cli_platform_storage.minimum_gb
     = List.fold_left
         (fun total (part : Sol_cli_platform_storage.part) -> total + part.gib)
         0
         Sol_cli_platform_storage.parts);
  Alcotest.(check bool)
    "the description names the components"
    true
    (contains (Sol_cli_platform_storage.describe ()) "GiB")
;;

let () =
  Alcotest.run
    "disk_quota"
    [ ( "observation"
      , [ Alcotest.test_case
            "reads the governing quota"
            `Quick
            test_reads_the_governing_quota
        ; Alcotest.test_case
            "a quota the region does not report is not zero"
            `Quick
            test_a_quota_the_region_does_not_report_is_not_zero
        ; Alcotest.test_case
            "an unparseable payload is an error"
            `Quick
            test_unparseable_payload_is_an_error
        ] )
    ; ( "policy"
      , [ Alcotest.test_case
            "sufficiency is the declared minimum"
            `Quick
            test_sufficiency_is_the_declared_minimum
        ; Alcotest.test_case
            "a spent quota refuses with the observed numbers"
            `Quick
            test_empty_quota_refuses_with_the_observed_numbers
        ; Alcotest.test_case
            "the declaration is described and self-consistent"
            `Quick
            test_the_declaration_is_described
        ] )
    ]
;;
