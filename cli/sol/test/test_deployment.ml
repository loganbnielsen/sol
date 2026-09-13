let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)

module D = Sol_cli_deployment

let contains needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with
  | Not_found -> false
;;

let index_of needle haystack =
  try Some (Str.search_forward (Str.regexp_string needle) haystack 0) with
  | Not_found -> None
;;

let id_a = Sol_cli_deployment_id.create ~now:1767225600.0 ~entropy:"seed-a"
let id_b = Sol_cli_deployment_id.create ~now:1767225700.0 ~entropy:"seed-b"

let sample : D.t =
  { deployment_id = Sol_cli_deployment_id.to_string id_a
  ; release_id = "r-0123456789abcdef"
  ; workspace = "myworkspace"
  ; environment = Some "prod"
  ; created_at = "2026-01-01T00:00:00Z"
  ; git_commit = "abc1234"
  ; git_dirty = false
  ; actor = Some "ci"
  ; target = Some "prod/aws/us-east-1"
  ; mode = "customer_cloud"
  ; requested_scope = "payments"
  }
;;

(* ── record shape ────────────────────────────────────────────────────────── *)

let test_json_round_trip () =
  match D.of_json (D.to_json sample) with
  | Error msg -> Alcotest.fail msg
  | Ok r ->
    check_string "deployment_id preserved" sample.deployment_id r.deployment_id;
    check_string "release_id preserved" sample.release_id r.release_id;
    check_string "created_at preserved" sample.created_at r.created_at;
    check_string "git_commit preserved" "abc1234" r.git_commit;
    check_bool "git_dirty preserved" false r.git_dirty;
    check_string
      "target preserved"
      "prod/aws/us-east-1"
      (Option.value r.target ~default:"");
    check_string "mode preserved" "customer_cloud" r.mode
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
    ("sol-deployment-" ^ sample.deployment_id)
    (D.configmap_name sample);
  let labels = member "metadata" json |> member "labels" in
  check_string "type label" "deployment" (labels |> member "sol.dev/type" |> to_string);
  check_string
    "release label is the join key to the release"
    sample.release_id
    (labels |> member "sol.dev/release" |> to_string);
  check_string
    "workspace label"
    "myworkspace"
    (labels |> member "sol.dev/workspace" |> to_string);
  let data = member "data" json in
  check_string
    "deployment_id in data"
    sample.deployment_id
    (member "deployment_id" data |> to_string);
  let record = member "record" data |> to_string in
  check_bool "release id in body" true (contains sample.release_id record);
  check_bool "git provenance in body" true (contains "abc1234" record)
;;

let test_json_is_deterministic () =
  check_string
    "same event, same bytes"
    (Yojson.Safe.to_string (D.to_json sample))
    (Yojson.Safe.to_string (D.to_json sample))
;;

(* ── validating both directions ──────────────────────────────────────────── *)

let test_validate_accepts_canonical_event () =
  match D.validate ~name:(D.configmap_name sample) sample with
  | Ok () -> ()
  | Error msg -> Alcotest.fail ("canonical event rejected: " ^ msg)
;;

let test_validate_rejects_wrong_name () =
  match D.validate ~name:"sol-deployment-d-20260101t000000z-ffffffffffffffff" sample with
  | Ok () -> Alcotest.fail "expected a name-direction failure"
  | Error msg -> check_bool "names the event" true (contains sample.deployment_id msg)
;;

(* A correctly named event that points at a release string which is not a release
   id: the name alone would miss it. *)
let test_validate_rejects_corrupt_release_pointer () =
  let corrupt = { sample with release_id = "not-a-release" } in
  match D.validate ~name:(D.configmap_name corrupt) corrupt with
  | Ok () -> Alcotest.fail "expected a release-pointer failure"
  | Error msg ->
    check_bool "reports the bad release" true (contains "invalid release" msg)
;;

(* ── reading back ────────────────────────────────────────────────────────── *)

let test_parse_kubectl_list_skips_invalid_items () =
  let item ?(name = D.configmap_name sample) json =
    `Assoc
      [ "metadata", `Assoc [ "name", `String name ]
      ; "data", `Assoc [ "record", `String json ]
      ]
  in
  let json =
    `Assoc
      [ ( "items"
        , `List
            [ item (Yojson.Safe.to_string (D.to_json sample))
            ; `Assoc []
            ; item "not json"
            ; item
                ~name:"sol-deployment-d-20260101t000000z-ffffffffffffffff"
                (Yojson.Safe.to_string (D.to_json sample))
            ] )
      ]
  in
  match D.parse_kubectl_list json with
  | Error msg -> Alcotest.fail msg
  | Ok records -> check_int "only the valid event" 1 (List.length records)
;;

let test_format_table_newest_first () =
  let newer =
    { sample with
      deployment_id = Sol_cli_deployment_id.to_string id_b
    ; created_at = "2026-01-01T00:10:00Z"
    }
  in
  let older = sample in
  let table = D.format_table [ older; newer ] in
  check_bool "header" true (contains "DEPLOYMENT" table);
  check_bool "release column" true (contains "RELEASE" table);
  let i_newer = index_of newer.deployment_id table
  and i_older = index_of older.deployment_id table in
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

let test_event_points_at_the_plans_release () =
  with_plan (fun plan ->
    let event =
      D.of_plan
        ~deployment_id:id_a
        ~now:1767225600.0
        ~git_commit:"abc1234"
        ~git_dirty:false
        ~actor:(Some "ci")
        ~target:(Some "prod/aws/us-east-1")
        plan
    in
    check_string
      "release_id is the plan's, consumed not rederived"
      (Sol_cli_release_id.to_string plan.Sol_cli_deployment_plan.release_id)
      event.release_id;
    check_string "workspace from the plan" "myworkspace" event.workspace;
    check_string "mode from the plan" "local" event.mode;
    check_string "requested scope from the plan" "payments" event.requested_scope)
;;

(* The acceptance criterion: two deploys of identical content produce one
   release_id and two deployment_ids, and provenance differences (commit, dirty,
   actor, time) never move the release. *)
let test_two_deploys_one_release () =
  with_plan (fun plan ->
    let first =
      D.of_plan
        ~deployment_id:id_a
        ~now:1767225600.0
        ~git_commit:"aaa1111"
        ~git_dirty:false
        ~actor:(Some "ci")
        ~target:(Some "prod/aws/us-east-1")
        plan
    and second =
      D.of_plan
        ~deployment_id:id_b
        ~now:1767225700.0
        ~git_commit:"bbb2222"
        ~git_dirty:true
        ~actor:(Some "alice")
        ~target:(Some "prod/aws/us-east-1")
        plan
    in
    check_string "one release" first.release_id second.release_id;
    check_bool
      "two deployment ids"
      true
      (not (String.equal first.deployment_id second.deployment_id));
    check_bool
      "provenance did not move the release"
      true
      (String.equal
         first.release_id
         (Sol_cli_release_id.to_string plan.Sol_cli_deployment_plan.release_id)))
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
            "rejects a corrupt release pointer"
            `Quick
            test_validate_rejects_corrupt_release_pointer
        ] )
    ; ( "read"
      , [ Alcotest.test_case
            "parse skips invalid items"
            `Quick
            test_parse_kubectl_list_skips_invalid_items
        ; Alcotest.test_case "table is newest first" `Quick test_format_table_newest_first
        ] )
    ; ( "of_plan"
      , [ Alcotest.test_case
            "points at the plan's release"
            `Quick
            test_event_points_at_the_plans_release
        ; Alcotest.test_case
            "two deploys, one release"
            `Quick
            test_two_deploys_one_release
        ] )
    ]
;;
