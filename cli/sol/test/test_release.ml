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

(* ── labels ──────────────────────────────────────────────────────────────── *)

let test_sanitize_label () =
  check_string "target path" "dev-aws-us-east-1" (R.sanitize_label "dev/aws/us-east-1");
  check_string "unit scope" "payments-charge_svc" (R.sanitize_label "payments/charge_svc");
  check_string "uppercase lowers" "prod" (R.sanitize_label "PROD");
  check_string "all separators collapses to none" "none" (R.sanitize_label "///")
;;

(* ── record shape ────────────────────────────────────────────────────────── *)

let sample_workload : R.workload =
  { domain = "payments"
  ; name = "charge_svc"
  ; primitive = "svc"
  ; image = "reg/myworkspace/charge-svc:abc1234"
  ; config = [ "LOG_LEVEL", "info" ]
  ; secrets = [ "DATABASE_URL", "db-secret" ]
  ; schedule = None
  ; replicas = 2
  ; cpu = "100m"
  ; memory = "128Mi"
  ; extra_labels = [ "team", "payments" ]
  }
;;

(* The id is derived from the record's own content, so a hand-built fixture is
   canonical by construction — exactly the property [validate] checks. *)
let sample_record : R.t =
  let placeholder =
    { R.release_id = "r-0000000000000000"
    ; workspace = "myworkspace"
    ; environment = Some "dev"
    ; workloads = [ sample_workload ]
    }
  in
  { placeholder with
    release_id = Sol_cli_release_id.to_string (R.derived_release_id placeholder)
  }
;;

let test_json_round_trip () =
  match R.of_json (R.to_json sample_record) with
  | Error msg -> Alcotest.fail msg
  | Ok r ->
    check_string "workspace preserved" "myworkspace" r.workspace;
    check_string "environment preserved" "dev" (Option.value r.environment ~default:"");
    check_int "one workload" 1 (List.length r.workloads);
    let w = List.hd r.workloads in
    check_string "image preserved" "reg/myworkspace/charge-svc:abc1234" w.image;
    check_string "config value preserved" "info" (List.assoc "LOG_LEVEL" w.config);
    check_string
      "secret reference preserved"
      "db-secret"
      (List.assoc "DATABASE_URL" w.secrets);
    check_int "replicas preserved" 2 w.replicas
;;

(* The AC: an immutable, labelled ConfigMap named by the release id, whose
   record carries the resolved content and no secret *values*. *)
let test_configmap_object () =
  let json = Yojson.Safe.from_string (R.to_configmap_json sample_record) in
  let open Yojson.Safe.Util in
  check_string "kind" "ConfigMap" (member "kind" json |> to_string);
  check_bool "immutable" true (member "immutable" json |> to_bool);
  check_string
    "name is the release id"
    (R.configmap_name sample_record)
    (member "metadata" json |> member "name" |> to_string);
  check_string
    "type label"
    "release"
    (member "metadata" json |> member "labels" |> member "sol.dev/type" |> to_string);
  let data = member "data" json in
  check_string
    "release_id in data"
    sample_record.release_id
    (member "release_id" data |> to_string);
  let record = member "record" data |> to_string in
  check_bool "workspace in body" true (contains "myworkspace" record);
  check_bool "workload in body" true (contains "charge_svc" record);
  check_bool "secret reference in body" true (contains "db-secret" record);
  check_bool "no unrelated secret value" false (contains "hunter2" record)
;;

(* The pointer is a claim about *which* record is selected, not a second copy of
   it: its payload is release_id and nothing else, so it cannot drift. *)
let test_current_pointer_is_minimal () =
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
  let data = member "data" json |> to_assoc in
  check_int "payload is release_id only" 1 (List.length data);
  check_string
    "points at the release"
    sample_record.release_id
    (List.assoc "release_id" data |> to_string)
;;

(* ── validating both directions ──────────────────────────────────────────── *)

let test_validate_accepts_canonical_record () =
  match R.validate ~name:(R.configmap_name sample_record) sample_record with
  | Ok () -> ()
  | Error msg -> Alcotest.fail ("canonical record rejected: " ^ msg)
;;

let test_validate_rejects_wrong_name () =
  match R.validate ~name:"sol-release-r-deadbeefdeadbeef" sample_record with
  | Ok () -> Alcotest.fail "expected a name-direction failure"
  | Error msg ->
    check_bool "names the record" true (contains sample_record.release_id msg)
;;

let test_validate_rejects_corrupt_content () =
  (* A correctly named record whose body does not rederive its id: exactly the
     corruption a name-only check would miss. *)
  let corrupt = { sample_record with workloads = [] } in
  match R.validate ~name:(R.configmap_name corrupt) corrupt with
  | Ok () -> Alcotest.fail "expected a content-direction failure"
  | Error msg -> check_bool "reports corruption" true (contains "corrupt" msg)
;;

(* ── reading back ────────────────────────────────────────────────────────── *)

let item ?(name = R.configmap_name sample_record) json =
  `Assoc
    [ "metadata", `Assoc [ "name", `String name ]
    ; "data", `Assoc [ "record", `String json ]
    ]
;;

let test_parse_kubectl_list_reads_valid_items () =
  let json =
    `Assoc [ "items", `List [ item (Yojson.Safe.to_string (R.to_json sample_record)) ] ]
  in
  match R.parse_kubectl_list json with
  | Error msg -> Alcotest.fail msg
  | Ok records -> check_int "one record" 1 (List.length records)
;;

(* FEAT-071: the store is authoritative, so a corrupt record is an error naming
   it, never something silently dropped. *)
let test_parse_kubectl_list_fails_closed_on_corrupt () =
  let json =
    `Assoc
      [ ( "items"
        , `List
            [ item (Yojson.Safe.to_string (R.to_json sample_record))
            ; item
                ~name:"sol-release-r-deadbeefdeadbeef"
                (Yojson.Safe.to_string (R.to_json sample_record))
            ; item "not json"
            ; `Assoc []
            ] )
      ]
  in
  match R.parse_kubectl_list json with
  | Ok records ->
    Alcotest.fail
      (Printf.sprintf "expected an error, got %d records" (List.length records))
  | Error msg ->
    check_bool "names corruption" true (contains "invalid record" msg);
    check_bool "names the record" true (contains "sol-release" msg)
;;

let test_format_table_lists_the_id () =
  let table = R.format_table [ sample_record ] in
  check_bool "id column present" true (contains sample_record.release_id table);
  check_bool "header present" true (contains "ID" table)
;;

(* ── of_plan / bundle determinism ────────────────────────────────────────── *)

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

let test_env : Sol_cli_deployment_plan.env_config =
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
;;

let test_service : Sol_cli_manifest.service =
  { domain = "payments"
  ; name = "charge_svc"
  ; primitive = Sol_cli_manifest.Svc
  ; dir = "app/payments/charge_svc"
  }
;;

let with_plan ~requested_scope f =
  let tmp = Filename.temp_dir "sol_test_release_plan" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file "app/payments/charge_svc/sol.toml" "";
    match
      Sol_cli_deployment_plan.of_services_result
        ~workspace:"myworkspace"
        ~env:test_env
        ~requested_scope
        [ test_service ]
    with
    | Error e -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string e)
    | Ok plan -> f plan)
;;

let test_of_plan_rederives_the_plan_identity () =
  with_plan ~requested_scope:"payments" (fun plan ->
    let r = R.of_plan plan in
    check_string
      "record id is the plan id"
      (Sol_cli_release_id.to_string plan.Sol_cli_deployment_plan.release_id)
      r.release_id;
    check_string
      "record content rederives the plan id"
      (Sol_cli_release_id.to_string plan.Sol_cli_deployment_plan.release_id)
      (Sol_cli_release_id.to_string (R.derived_release_id r));
    check_int "one resolved workload" 1 (List.length r.workloads);
    check_string "workload name" "charge_svc" (List.hd r.workloads).name;
    check_bool "image recorded" true (contains "charge-svc" (List.hd r.workloads).image))
;;

(* The step-6 promise at the artifact layer: same content -> same id ->
   byte-for-byte the same record, even though the two plans were asked for by
   different scopes (scope is intent, not released state). *)
let test_same_content_same_record () =
  with_plan ~requested_scope:"payments" (fun plan_a ->
    with_plan ~requested_scope:"workspace" (fun plan_b ->
      let a = R.of_plan plan_a
      and b = R.of_plan plan_b in
      check_string "same id" a.release_id b.release_id;
      check_string "same record bytes" (R.to_configmap_json a) (R.to_configmap_json b)))
;;

let test_bundle_files_are_deterministic () =
  let files = R.bundle_files sample_record in
  check_int "record + pointer" 2 (List.length files);
  check_bool
    "record file is named by the id"
    true
    (List.mem_assoc (R.configmap_name sample_record ^ ".yaml") files);
  check_bool "pointer file present" true (List.mem_assoc "sol-current-release.yaml" files);
  check_bool
    "record content is stable"
    true
    (List.assoc (R.configmap_name sample_record ^ ".yaml") files
     = R.to_configmap_json sample_record)
;;

let () =
  Alcotest.run
    "release"
    [ "labels", [ Alcotest.test_case "sanitization" `Quick test_sanitize_label ]
    ; ( "record"
      , [ Alcotest.test_case "json round trip" `Quick test_json_round_trip
        ; Alcotest.test_case "configmap object" `Quick test_configmap_object
        ; Alcotest.test_case "pointer is minimal" `Quick test_current_pointer_is_minimal
        ] )
    ; ( "validate"
      , [ Alcotest.test_case
            "accepts a canonical record"
            `Quick
            test_validate_accepts_canonical_record
        ; Alcotest.test_case
            "rejects a wrong name"
            `Quick
            test_validate_rejects_wrong_name
        ; Alcotest.test_case
            "rejects corrupt content"
            `Quick
            test_validate_rejects_corrupt_content
        ] )
    ; ( "read"
      , [ Alcotest.test_case
            "reads valid items"
            `Quick
            test_parse_kubectl_list_reads_valid_items
        ; Alcotest.test_case
            "fails closed on corrupt records"
            `Quick
            test_parse_kubectl_list_fails_closed_on_corrupt
        ; Alcotest.test_case "table lists the id" `Quick test_format_table_lists_the_id
        ] )
    ; ( "of_plan"
      , [ Alcotest.test_case
            "rederives the plan identity"
            `Quick
            test_of_plan_rederives_the_plan_identity
        ; Alcotest.test_case
            "same content, same record"
            `Quick
            test_same_content_same_record
        ; Alcotest.test_case
            "bundle files are deterministic"
            `Quick
            test_bundle_files_are_deterministic
        ] )
    ]
;;
