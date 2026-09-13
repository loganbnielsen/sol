let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)

module R = Sol_cli_release

let contains needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with
  | Not_found -> false
;;

(* ── id / timestamp / labels ─────────────────────────────────────────────── *)

let test_release_id_format () =
  let id = R.generate_release_id ~now:1_700_000_000.0 ~commit:"ABC1234" in
  check_string "utc, lowercase, dns-safe" "20231114t221320z-abc1234" id
;;

let test_rfc3339 () =
  check_string "utc" "2023-11-14T22:13:20Z" (R.rfc3339_utc 1_700_000_000.0)
;;

let test_sanitize_label () =
  check_string "target path" "dev-aws-us-east-1" (R.sanitize_label "dev/aws/us-east-1");
  check_string "unit scope" "payments-charge_svc" (R.sanitize_label "payments/charge_svc");
  check_string "uppercase lowers" "prod" (R.sanitize_label "PROD");
  check_string "all separators collapses to none" "none" (R.sanitize_label "///")
;;

(* ── record shape ────────────────────────────────────────────────────────── *)

let sample_record : R.t =
  { release_id = "20231114t221320z-abc1234"
  ; created_at = "2023-11-14T22:13:20Z"
  ; workspace = "myworkspace"
  ; target = "dev/aws/us-east-1"
  ; mode = "deploy"
  ; git_commit = "abc1234"
  ; git_dirty = false
  ; requested_scope = "payments"
  ; workloads =
      [ { domain = "payments"
        ; name = "charge_svc"
        ; image = "reg/myworkspace/charge-svc:abc1234"
        ; config_keys = [ "LOG_LEVEL" ]
        ; secret_keys = [ "DATABASE_URL" ]
        }
      ]
  ; migrations = [ "0001_init.sql" ]
  }
;;

let test_json_round_trip () =
  match R.of_json (R.to_json sample_record) with
  | Error msg -> Alcotest.fail msg
  | Ok r ->
    check_string "scope preserved" "payments" r.requested_scope;
    check_string "commit preserved" "abc1234" r.git_commit;
    check_bool "dirty preserved" false r.git_dirty;
    check_int "one workload" 1 (List.length r.workloads);
    check_string
      "image preserved"
      "reg/myworkspace/charge-svc:abc1234"
      (List.hd r.workloads).image
;;

(* The AC: an immutable, labelled ConfigMap whose record carries the requested
   scope and the resolved set, and no secret *values*. *)
let test_configmap_object () =
  let json = Yojson.Safe.from_string (R.to_configmap_json sample_record) in
  let open Yojson.Safe.Util in
  check_string "kind" "ConfigMap" (member "kind" json |> to_string);
  check_bool "immutable" true (member "immutable" json |> to_bool);
  check_string
    "type label"
    "release"
    (member "metadata" json |> member "labels" |> member "sol.dev/type" |> to_string);
  check_string
    "scope label"
    "payments"
    (member "metadata" json |> member "labels" |> member "sol.dev/scope" |> to_string);
  check_string
    "target label sanitized"
    "dev-aws-us-east-1"
    (member "metadata" json |> member "labels" |> member "sol.dev/target" |> to_string);
  let record = member "data" json |> member "record" |> to_string in
  check_bool "scope in body" true (contains "\"requested_scope\":\"payments\"" record);
  check_bool "resolved workload in body" true (contains "charge_svc" record);
  check_bool "secret key name recorded" true (contains "DATABASE_URL" record);
  check_bool "no secret value" false (contains "hunter2" record)
;;

let test_current_pointer_names_release () =
  let json = Yojson.Safe.from_string (R.to_current_configmap_json sample_record) in
  let open Yojson.Safe.Util in
  check_string
    "name"
    "sol-release-current-myworkspace"
    (member "metadata" json |> member "name" |> to_string);
  check_string
    "underscore workspace yields a valid name"
    "sol-release-current-ci-smoke"
    (R.current_configmap_name ~workspace:"ci_smoke");
  check_string
    "points at the release"
    (R.configmap_name sample_record)
    (Printf.sprintf
       "sol-release-%s"
       (member "data" json |> member "release_id" |> to_string))
;;

(* ── reading back ────────────────────────────────────────────────────────── *)

let test_parse_kubectl_list_skips_items_without_a_record () =
  let item json = `Assoc [ "data", `Assoc [ "record", `String json ] ] in
  let json =
    `Assoc
      [ ( "items"
        , `List
            [ item (Yojson.Safe.to_string (R.to_json sample_record))
            ; `Assoc []
            ; item "not json"
            ] )
      ]
  in
  match R.parse_kubectl_list json with
  | Error msg -> Alcotest.fail msg
  | Ok records -> check_int "only the valid record" 1 (List.length records)
;;

let test_format_table_newest_first () =
  let older =
    { sample_record with R.release_id = "older"; created_at = "2023-01-01T00:00:00Z" }
  in
  let newer =
    { sample_record with R.release_id = "newer"; created_at = "2024-01-01T00:00:00Z" }
  in
  let table = R.format_table [ older; newer ] in
  let pos needle = Str.search_forward (Str.regexp_string needle) table 0 in
  check_bool "newest row first" true (pos "newer" < pos "older");
  check_bool "header present" true (contains "ID" table)
;;

(* ── of_plan ─────────────────────────────────────────────────────────────── *)

let mkdirs path =
  let rec go p =
    if p = "." || p = "/" || p = ""
    then ()
    else (
      go (Filename.dirname p);
      try Unix.mkdir p 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  go path
;;

let write_file path content =
  mkdirs (Filename.dirname path);
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let with_cwd dir f =
  let old = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir old) f
;;

let test_of_plan_records_scope_and_resolved_set () =
  let tmp = Filename.temp_dir "sol_test_release_plan" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file "app/payments/charge_svc/sol.toml" "";
    let env : Sol_cli_deployment_plan.env_config =
      { name = "local"
      ; mode = Sol_cli_deployment_plan.Local
      ; registry = "sol-registry:5000"
      ; image_tag = "dev"
      ; env = None
      ; region = None
      ; base_domain = None
      ; cluster_issuer = "letsencrypt-prod"
      ; secret_backend = Sol_cli_manifest.Kubernetes_live
      }
    in
    let service : Sol_cli_manifest.service =
      { domain = "payments"
      ; name = "charge_svc"
      ; primitive = Sol_cli_manifest.Svc
      ; dir = "app/payments/charge_svc"
      }
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~workspace:"myworkspace"
        ~env
        ~requested_scope:"payments"
        [ service ]
    with
    | Error e -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string e)
    | Ok plan ->
      let r =
        R.of_plan
          ~workspace:"myworkspace"
          ~target:"local"
          ~mode:"local"
          ~git_commit:"abc1234"
          ~git_dirty:false
          plan
      in
      check_string "requested scope is recorded" "payments" r.requested_scope;
      check_int "one resolved workload" 1 (List.length r.workloads);
      check_string "workload name" "charge_svc" (List.hd r.workloads).name;
      check_bool "image recorded" true (contains "charge-svc" (List.hd r.workloads).image))
;;

let () =
  Alcotest.run
    "release"
    [ ( "id"
      , [ Alcotest.test_case "format" `Quick test_release_id_format
        ; Alcotest.test_case "rfc3339 utc" `Quick test_rfc3339
        ; Alcotest.test_case "label sanitization" `Quick test_sanitize_label
        ] )
    ; ( "record"
      , [ Alcotest.test_case "json round trip" `Quick test_json_round_trip
        ; Alcotest.test_case "configmap object" `Quick test_configmap_object
        ; Alcotest.test_case "current pointer" `Quick test_current_pointer_names_release
        ] )
    ; ( "read"
      , [ Alcotest.test_case
            "parse skips invalid items"
            `Quick
            test_parse_kubectl_list_skips_items_without_a_record
        ; Alcotest.test_case "table is newest first" `Quick test_format_table_newest_first
        ] )
    ; ( "of_plan"
      , [ Alcotest.test_case
            "records scope and resolved set"
            `Quick
            test_of_plan_records_scope_and_resolved_set
        ] )
    ]
;;
