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
  ; availability = "single"
  ; cpu = "100m"
  ; memory = "128Mi"
  ; extra_labels = [ "team", "payments" ]
  ; volumes = [ "pgdata", "/var/lib/postgresql/data", "1Gi", "read_write_once" ]
  ; rollout = "canary:w10,p30,w100"
  ; ingress_host = Some "charge.example.com"
  ; ingress_path = Some "/"
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = [ "CHECKOUT_SVC_URL", "checkout", "checkout-svc", "myworkspace-checkout" ]
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
    ; migrations = [ "0001_notifications.sql" ]
    ; apply_mode = R.Direct
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
    check_int "replicas preserved" 2 w.replicas;
    Alcotest.(check (list string))
      "migrations preserved"
      [ "0001_notifications.sql" ]
      r.migrations
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
  check_string
    "digest is the record's own digest"
    (R.record_digest sample_record)
    (member "record_digest" data |> to_string);
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

let item ?(name = R.configmap_name sample_record) ?digest json =
  let digest =
    match digest with
    | Some d -> d
    | None -> Digest.to_hex (Digest.string json)
  in
  `Assoc
    [ "metadata", `Assoc [ "name", `String name ]
    ; "data", `Assoc [ "record", `String json; "record_digest", `String digest ]
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

(* FEAT-072 retention orders by the cluster-assigned creation timestamp, which is
   object metadata and never part of the record body. *)
let test_parse_kubectl_list_with_creation () =
  let record_body = Yojson.Safe.to_string (R.to_json sample_record) in
  let json =
    `Assoc
      [ ( "items"
        , `List
            [ `Assoc
                [ ( "metadata"
                  , `Assoc
                      [ "name", `String (R.configmap_name sample_record)
                      ; "creationTimestamp", `String "2026-01-01T00:00:00Z"
                      ] )
                ; ( "data"
                  , `Assoc
                      [ "record", `String record_body
                      ; ( "record_digest"
                        , `String (Digest.to_hex (Digest.string record_body)) )
                      ] )
                ]
            ] )
      ]
  in
  match R.parse_kubectl_list_with_creation json with
  | Error msg -> Alcotest.fail msg
  | Ok [ (record, created_at) ] ->
    check_string "record id" sample_record.R.release_id record.R.release_id;
    check_string "creation timestamp" "2026-01-01T00:00:00Z" created_at
  | Ok _ -> Alcotest.fail "expected exactly one record"
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

(* FEAT-066: the full-record digest makes the *complete* body -- including the
   non-identity [migrations]/[apply_mode] fields [release_id] cannot cover --
   tamper-evident. A body altered after it was written (e.g. by editing the
   ConfigMap) no longer matches the stored digest. *)
let test_of_kubectl_item_accepts_canonical_record () =
  match R.of_kubectl_item (item (R.record_json_string sample_record)) with
  | Error msg -> Alcotest.fail msg
  | Ok r -> check_string "round-trips the id" sample_record.release_id r.release_id
;;

let test_of_kubectl_item_rejects_missing_digest () =
  let no_digest =
    `Assoc
      [ "metadata", `Assoc [ "name", `String (R.configmap_name sample_record) ]
      ; "data", `Assoc [ "record", `String (R.record_json_string sample_record) ]
      ]
  in
  match R.of_kubectl_item no_digest with
  | Ok _ -> Alcotest.fail "expected a missing digest to fail closed"
  | Error msg ->
    check_bool "names the format problem" true (contains "missing integrity digest" msg)
;;

let test_of_kubectl_item_rejects_tampered_body () =
  let tampered = { sample_record with migrations = [ "9999_evil.sql" ] } in
  let record_string = R.record_json_string tampered in
  (* The stored digest is the *original* record's, so the altered body's digest
     no longer matches. *)
  match
    R.of_kubectl_item (item ~digest:(R.record_digest sample_record) record_string)
  with
  | Ok _ -> Alcotest.fail "expected a tampered body to fail closed"
  | Error msg ->
    check_bool "reports integrity failure" true (contains "integrity validation" msg)
;;

(* The precise finding: a change to [migrations] does not move [release_id], so
   [validate] alone would accept it. The digest is what catches it -- the
   safety-relevant field is not the one the identity protects. *)
let test_migrations_tampering_is_caught_by_digest_not_validate () =
  let tampered = { sample_record with migrations = [ "9999_evil.sql" ] } in
  (match R.validate ~name:(R.configmap_name tampered) tampered with
   | Ok () -> ()
   | Error msg ->
     Alcotest.fail ("a migrations-only change should still rederive the id: " ^ msg));
  match
    R.of_kubectl_item
      (item ~digest:(R.record_digest sample_record) (R.record_json_string tampered))
  with
  | Ok _ -> Alcotest.fail "expected the digest to catch a migrations-only change"
  | Error msg ->
    check_bool "reports integrity failure" true (contains "integrity validation" msg)
;;

(* ── canonicalization ──────────────────────────────────────────────────────
   The digest is only meaningful if the body it hashes is a total function of
   the record. These pin that: order-independence, a total order even for
   duplicate keys, and a known vector so a change to the canonical rules or the
   serializer is a deliberate, reviewed decision. *)

let shuffled_workload : R.workload =
  { sample_workload with
    config = [ "B", "2"; "A", "1" ]
  ; secrets = [ "Y", "y"; "X", "x" ]
  ; extra_labels = [ "z", "26"; "a", "1" ]
  ; volumes = [ "v2", "/2", "2Gi", "ReadWriteMany"; "v1", "/1", "1Gi", "ReadWriteOnce" ]
  ; calls = [ "Z_URL", "z", "z-svc", "ns-z"; "A_URL", "a", "a-svc", "ns-a" ]
  }
;;

let ordered_workload : R.workload =
  { shuffled_workload with
    config = [ "A", "1"; "B", "2" ]
  ; secrets = [ "X", "x"; "Y", "y" ]
  ; extra_labels = [ "a", "1"; "z", "26" ]
  ; volumes = [ "v1", "/1", "1Gi", "ReadWriteOnce"; "v2", "/2", "2Gi", "ReadWriteMany" ]
  ; calls = [ "A_URL", "a", "a-svc", "ns-a"; "Z_URL", "z", "z-svc", "ns-z" ]
  }
;;

(* A second workload whose name sorts before [sample_workload]'s, so workload
   list order can be reversed too. *)
let earlier_workload : R.workload =
  { sample_workload with name = "aaa_svc"; image = "reg/myworkspace/aaa-svc:abc1234" }
;;

let test_record_digest_is_order_independent () =
  let forward =
    { sample_record with
      workloads = [ shuffled_workload; earlier_workload ]
    ; migrations = [ "0002_b.sql"; "0001_a.sql" ]
    }
  in
  let reversed =
    { sample_record with
      workloads = [ earlier_workload; ordered_workload ]
    ; migrations = [ "0001_a.sql"; "0002_b.sql" ]
    }
  in
  check_string
    "canonical body is order-independent"
    (R.record_json_string forward)
    (R.record_json_string reversed);
  check_string
    "canonical digest is order-independent"
    (R.record_digest forward)
    (R.record_digest reversed)
;;

(* Key-only ordering is not a total order: duplicate keys would fall back on
   [List.sort]'s (unspecified) stability, so the canonical form must break the
   tie on the value. Mostly the planner rejects collisions, but maps are not
   sets and the encoder may not assume it. *)
let test_record_digest_is_total_for_duplicate_keys () =
  let with_config config =
    { sample_record with workloads = [ { sample_workload with config } ] }
  in
  check_string
    "duplicate-key order is total"
    (R.record_digest (with_config [ "K", "a"; "K", "b" ]))
    (R.record_digest (with_config [ "K", "b"; "K", "a" ]))
;;

(* A known vector for the canonical serialization. If this changes, the
   canonical rules (or the JSON serializer) changed: either is a deliberate
   decision that must be made here, not a silent redefinition of every stored
   record's digest. AUDIT-080 added the workload availability string to the
   record, so this vector moved deliberately. *)
let test_record_digest_known_vector () =
  check_string
    "known canonical digest"
    "f5cc20f7028d7daafd783707c5a41280"
    (R.record_digest sample_record)
;;

(* FEAT-066: apply_mode is required historical metadata; a record that omits it
   or carries an unknown value fails closed rather than defaulting to Direct. *)
let test_apply_mode_round_trips () =
  match R.of_json (R.to_json { sample_record with apply_mode = R.Gitops }) with
  | Error msg -> Alcotest.fail msg
  | Ok r -> check_bool "gitops preserved" true (r.apply_mode = R.Gitops)
;;

let without_field key json =
  match json with
  | `Assoc kvs -> `Assoc (List.filter (fun (k, _) -> k <> key) kvs)
  | other -> other
;;

let test_apply_mode_missing_fails_closed () =
  match R.of_json (without_field "apply_mode" (R.to_json sample_record)) with
  | Ok _ -> Alcotest.fail "expected a missing apply_mode to fail closed"
  | Error msg -> check_bool "names the field" true (contains "apply_mode" msg)
;;

let test_apply_mode_unknown_fails_closed () =
  let json =
    match R.to_json sample_record with
    | `Assoc kvs ->
      `Assoc
        (List.map
           (fun (k, v) -> if k = "apply_mode" then k, `String "sideways" else k, v)
           kvs)
    | other -> other
  in
  match R.of_json json with
  | Ok _ -> Alcotest.fail "expected an unknown apply_mode to fail closed"
  | Error msg -> check_bool "names the field" true (contains "apply_mode" msg)
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
    let r = R.of_plan ~apply_mode:R.Direct plan in
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
      let a = R.of_plan ~apply_mode:R.Direct plan_a
      and b = R.of_plan ~apply_mode:R.Direct plan_b in
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
        ; Alcotest.test_case "apply_mode round-trips" `Quick test_apply_mode_round_trips
        ; Alcotest.test_case
            "missing apply_mode fails closed"
            `Quick
            test_apply_mode_missing_fails_closed
        ; Alcotest.test_case
            "unknown apply_mode fails closed"
            `Quick
            test_apply_mode_unknown_fails_closed
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
            "reads creation timestamps (FEAT-072 retention)"
            `Quick
            test_parse_kubectl_list_with_creation
        ; Alcotest.test_case
            "fails closed on corrupt records"
            `Quick
            test_parse_kubectl_list_fails_closed_on_corrupt
        ; Alcotest.test_case
            "accepts a canonical item"
            `Quick
            test_of_kubectl_item_accepts_canonical_record
        ; Alcotest.test_case
            "rejects a missing integrity digest"
            `Quick
            test_of_kubectl_item_rejects_missing_digest
        ; Alcotest.test_case
            "rejects a tampered body"
            `Quick
            test_of_kubectl_item_rejects_tampered_body
        ; Alcotest.test_case
            "catches migrations tampering that validate misses"
            `Quick
            test_migrations_tampering_is_caught_by_digest_not_validate
        ; Alcotest.test_case "table lists the id" `Quick test_format_table_lists_the_id
        ] )
    ; ( "canonicalization"
      , [ Alcotest.test_case
            "digest is order-independent"
            `Quick
            test_record_digest_is_order_independent
        ; Alcotest.test_case
            "duplicate keys are totally ordered"
            `Quick
            test_record_digest_is_total_for_duplicate_keys
        ; Alcotest.test_case
            "known canonical digest"
            `Quick
            test_record_digest_known_vector
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
