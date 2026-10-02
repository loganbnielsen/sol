let contains haystack needle =
  let n = String.length needle
  and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  n = 0 || at 0
;;

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

let test_the_declaration_is_described () =
  Alcotest.(check bool)
    "a minimum is declared"
    true
    (Sol_cli_platform_storage.minimum_gb > 0);
  Alcotest.(check bool)
    "every part carries its provenance"
    true
    (Sol_cli_platform_storage.parts
     |> List.for_all (fun (part : Sol_cli_platform_storage.part) ->
       String.trim part.component <> ""
       && String.trim part.provenance <> ""
       && part.gib > 0));
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

let%test "observation: reads the governing quota" = test_reads_the_governing_quota ()

let%test "observation: a quota the region does not report is not zero" =
  test_a_quota_the_region_does_not_report_is_not_zero ()
;;

let%test "observation: an unparseable payload is an error" =
  test_unparseable_payload_is_an_error ()
;;

let%test "policy: sufficiency is the declared minimum" =
  test_sufficiency_is_the_declared_minimum ()
;;

let%test "policy: a spent quota refuses with the observed numbers" =
  test_empty_quota_refuses_with_the_observed_numbers ()
;;

let%test "policy: the declaration is described and self-consistent" =
  test_the_declaration_is_described ()
;;
