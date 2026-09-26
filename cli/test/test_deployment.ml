let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)

module D = Sol_cli_deployment

let contains needle haystack = Sol_cli_string.contains ~needle haystack

let index_of needle haystack =
  try Some (Str.search_forward (Str.regexp_string needle) haystack 0) with
  | Not_found -> None
;;

let id_a = Sol_cli_deployment_id.create ~now:1767225600.0 ~entropy:"seed-a"
let id_b = Sol_cli_deployment_id.create ~now:1767225700.0 ~entropy:"seed-b"
let release_a = Result.get_ok (Sol_cli_release_id.of_string "r-0123456789abcdef")
let id_a_string = Sol_cli_deployment_id.to_string id_a
let release_a_string = Sol_cli_release_id.to_string release_a

let sample : D.t =
  { deployment_id = id_a
  ; release_id = release_a
  ; workspace = "myworkspace"
  ; environment = Some "prod"
  ; created_at = "2026-01-01T00:00:00Z"
  ; git_commit = "abc1234"
  ; git_dirty = false
  ; actor = Some "ci"
  ; target = Some "prod/aws/us-east-1"
  ; mode = "customer_cloud"
  ; requested_scope = "payments"
  ; profile = None
  ; outcome = D.Applied
  }
;;

(* ── record shape ────────────────────────────────────────────────────────── *)

let test_json_round_trip () =
  match D.of_json (D.to_json sample) with
  | Error msg -> Alcotest.fail msg
  | Ok r ->
    check_string
      "deployment_id preserved"
      id_a_string
      (Sol_cli_deployment_id.to_string r.deployment_id);
    check_string
      "release_id preserved"
      release_a_string
      (Sol_cli_release_id.to_string r.release_id);
    check_string "created_at preserved" sample.created_at r.created_at;
    check_string "git_commit preserved" "abc1234" r.git_commit;
    check_bool "git_dirty preserved" false r.git_dirty;
    check_string
      "target preserved"
      "prod/aws/us-east-1"
      (Option.value r.target ~default:"");
    check_string "mode preserved" "customer_cloud" r.mode;
    check_bool "outcome preserved" true (r.outcome = D.Applied)
;;

let test_configmap_object () =
  let json = Yojson.Safe.from_string (D.to_configmap_json sample) in
  let open Yojson.Safe.Util in
  check_string "kind" "ConfigMap" (member "kind" json |> to_string);
  check_bool "immutable" true (member "immutable" json |> to_bool);
  check_string
    "name is the deployment id"
    (D.configmap_name sample)
    (member "metadata" json |> member "name" |> to_string);
  check_string
    "name mirrors the release convention"
    ("sol-deployment-" ^ id_a_string)
    (D.configmap_name sample);
  let labels = member "metadata" json |> member "labels" in
  check_string "type label" "deployment" (labels |> member "sol.dev/type" |> to_string);
  check_string
    "release label is the join key to the release"
    release_a_string
    (labels |> member "sol.dev/release" |> to_string);
  check_string
    "workspace label"
    "myworkspace"
    (labels |> member "sol.dev/workspace" |> to_string);
  let data = member "data" json in
  check_string
    "deployment_id in data"
    id_a_string
    (member "deployment_id" data |> to_string);
  let record = member "record" data |> to_string in
  check_bool "release id in body" true (contains release_a_string record);
  check_bool "git provenance in body" true (contains "abc1234" record);
  check_bool "outcome in body" true (contains "applied" record)
;;

let test_json_is_deterministic () =
  check_string
    "same event, same bytes"
    (Yojson.Safe.to_string (D.to_json sample))
    (Yojson.Safe.to_string (D.to_json sample))
;;

(* ── validating the read path ────────────────────────────────────────────── *)

let test_validate_accepts_canonical_event () =
  match D.validate ~name:(D.configmap_name sample) sample with
  | Ok () -> ()
  | Error msg -> Alcotest.fail ("canonical event rejected: " ^ msg)
;;

let test_validate_rejects_wrong_name () =
  match D.validate ~name:"sol-deployment-d-20260101t000000z-ffffffffffffffff" sample with
  | Ok () -> Alcotest.fail "expected a name-direction failure"
  | Error msg -> check_bool "names the event" true (contains id_a_string msg)
;;

let with_field key value json =
  match json with
  | `Assoc kvs ->
    `Assoc (List.map (fun (k, v) -> if String.equal k key then k, value else k, v) kvs)
  | other -> other
;;

(* FEAT-071: ids are parsed at the boundary, so a malformed one is an error here
   rather than a string that later reaches a name or a label. *)
let test_of_json_rejects_a_bad_deployment_id () =
  let bad = with_field "deployment_id" (`String "not-an-id") (D.to_json sample) in
  match D.of_json bad with
  | Ok _ -> Alcotest.fail "expected an invalid deployment id to be rejected"
  | Error msg -> check_bool "names the problem" true (contains "invalid id" msg)
;;

let test_of_json_rejects_a_bad_release_id () =
  let bad = with_field "release_id" (`String "nope") (D.to_json sample) in
  match D.of_json bad with
  | Ok _ -> Alcotest.fail "expected an invalid release id to be rejected"
  | Error msg -> check_bool "names the problem" true (contains "invalid release id" msg)
;;

let test_of_json_rejects_unknown_outcome () =
  let bad = with_field "outcome" (`String "maybe") (D.to_json sample) in
  match D.of_json bad with
  | Ok _ -> Alcotest.fail "expected an unknown outcome to be rejected"
  | Error msg -> check_bool "names the outcome" true (contains "outcome" msg)
;;

(* ── reading back ────────────────────────────────────────────────────────── *)

let item ?(name = D.configmap_name sample) json =
  `Assoc
    [ "metadata", `Assoc [ "name", `String name ]
    ; "data", `Assoc [ "record", `String json ]
    ]
;;

let test_parse_kubectl_list_reads_valid_items () =
  let failed = { sample with outcome = D.Apply_failed } in
  let json =
    `Assoc
      [ ( "items"
        , `List
            [ item (Yojson.Safe.to_string (D.to_json sample))
            ; item
                ~name:(D.configmap_name failed)
                (Yojson.Safe.to_string (D.to_json failed))
            ] )
      ]
  in
  match D.parse_kubectl_list json with
  | Error msg -> Alcotest.fail msg
  | Ok records -> check_int "both events" 2 (List.length records)
;;

(* FEAT-071: the store is authoritative, so a corrupt record is an error naming
   it, never something silently dropped. *)
let test_parse_kubectl_list_fails_closed_on_corrupt () =
  let json =
    `Assoc
      [ ( "items"
        , `List
            [ item (Yojson.Safe.to_string (D.to_json sample))
            ; item "not json"
            ; item
                ~name:"sol-deployment-d-20260101t000000z-ffffffffffffffff"
                (Yojson.Safe.to_string (D.to_json sample))
            ] )
      ]
  in
  match D.parse_kubectl_list json with
  | Ok records ->
    Alcotest.fail
      (Printf.sprintf "expected an error, got %d records" (List.length records))
  | Error msg ->
    check_bool "names corruption" true (contains "invalid record" msg);
    check_bool "names the record" true (contains "sol-deployment" msg)
;;

let test_format_table_newest_first_with_status () =
  let newer =
    { sample with
      deployment_id = id_b
    ; created_at = "2026-01-01T00:10:00Z"
    ; outcome = D.Apply_failed
    }
  in
  let older = sample in
  let table = D.format_table [ older; newer ] in
  check_bool "header" true (contains "DEPLOYMENT" table);
  check_bool "status column" true (contains "STATUS" table);
  check_bool "applied shown" true (contains "applied" table);
  check_bool "failed shown" true (contains "apply_failed" table);
  let i_newer = index_of (Sol_cli_deployment_id.to_string id_b) table
  and i_older = index_of id_a_string table in
  match i_newer, i_older with
  | Some a, Some b -> check_bool "newest first" true (a < b)
  | _ -> Alcotest.fail "both ids must appear in the table"
;;

(* ── of_plan: the acceptance criterion ───────────────────────────────────── *)

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

let with_plan f =
  let tmp = Filename.temp_dir "sol_test_deployment_plan" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file "app/payments/charge_svc/sol.toml" "";
    match
      Sol_cli_deployment_plan.of_services_result
        ~workspace:"myworkspace"
        ~env:test_env
        ~requested_scope:"payments"
        [ test_service ]
    with
    | Error e -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string e)
    | Ok plan -> f plan)
;;

let of_plan plan ?(id = id_a) ?(now = 1767225600.0) ~outcome () =
  D.of_plan
    ~deployment_id:id
    ~now
    ~git_commit:"abc1234"
    ~git_dirty:false
    ~actor:(Some "ci")
    ~target:(Some "prod/aws/us-east-1")
    ~outcome
    plan
;;

let test_event_points_at_the_plans_release () =
  with_plan (fun plan ->
    let event = of_plan plan ~outcome:D.Applied () in
    check_string
      "release_id is the plan's, consumed not rederived"
      (Sol_cli_release_id.to_string plan.Sol_cli_deployment_plan.release_id)
      (Sol_cli_release_id.to_string event.release_id);
    check_string "workspace from the plan" "myworkspace" event.workspace;
    check_string "mode from the plan" "local" event.mode;
    check_string "requested scope from the plan" "payments" event.requested_scope)
;;

(* FEAT-071: an attempt and a failed attempt are both events. Two attempts of
   identical content produce one release_id and two deployment_ids; only the
   outcome distinguishes them. *)
let test_two_attempts_one_release () =
  with_plan (fun plan ->
    let applied = of_plan plan ~outcome:D.Applied () in
    let failed = of_plan plan ~id:id_b ~now:1767225700.0 ~outcome:D.Apply_failed () in
    check_bool
      "one release"
      true
      (String.equal
         (Sol_cli_release_id.to_string applied.release_id)
         (Sol_cli_release_id.to_string failed.release_id));
    check_bool
      "two deployment ids"
      true
      (not
         (String.equal
            (Sol_cli_deployment_id.to_string applied.deployment_id)
            (Sol_cli_deployment_id.to_string failed.deployment_id)));
    check_bool "first applied" true (applied.outcome = D.Applied);
    check_bool "second failed" true (failed.outcome = D.Apply_failed))
;;

let () =
  Alcotest.run
    "deployment"
    [ ( "record"
      , [ Alcotest.test_case "json round trip" `Quick test_json_round_trip
        ; Alcotest.test_case "configmap object" `Quick test_configmap_object
        ; Alcotest.test_case "json is deterministic" `Quick test_json_is_deterministic
        ] )
    ; ( "validate"
      , [ Alcotest.test_case
            "accepts a canonical event"
            `Quick
            test_validate_accepts_canonical_event
        ; Alcotest.test_case
            "rejects a wrong name"
            `Quick
            test_validate_rejects_wrong_name
        ; Alcotest.test_case
            "rejects a bad deployment id"
            `Quick
            test_of_json_rejects_a_bad_deployment_id
        ; Alcotest.test_case
            "rejects a bad release id"
            `Quick
            test_of_json_rejects_a_bad_release_id
        ; Alcotest.test_case
            "rejects an unknown outcome"
            `Quick
            test_of_json_rejects_unknown_outcome
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
        ; Alcotest.test_case
            "table is newest first with status"
            `Quick
            test_format_table_newest_first_with_status
        ] )
    ; ( "of_plan"
      , [ Alcotest.test_case
            "points at the plan's release"
            `Quick
            test_event_points_at_the_plans_release
        ; Alcotest.test_case
            "two attempts, one release"
            `Quick
            test_two_attempts_one_release
        ] )
    ]
;;
