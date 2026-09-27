(* REFAC-132: the JSON boundary, and the decoders moved onto it. Each pair holds
   the rule both ways: malformed or missing structure is an Error, and the empty
   answer -- the one the tool actually gave -- is Ok. *)

let is_error label = function
  | Ok _ -> Alcotest.failf "%s: a malformed read was accepted" label
  | Error (_ : string) -> ()
;;

let ok label = function
  | Ok v -> v
  | Error msg -> Alcotest.failf "%s: %s" label msg
;;

let test_boundary () =
  let j =
    ok "decode" (Sol_cli_json.decode ~what:"x" {|{"a":{"b":1},"s":"t","n":null}|})
  in
  Alcotest.(check (option int))
    "path"
    (Some 1)
    (Sol_cli_json.field [ "a"; "b" ] j |> Sol_cli_json.int);
  Alcotest.(check bool)
    "a path through a non-object is Null, not an exception"
    true
    (Sol_cli_json.field [ "s"; "deeper" ] j = `Null);
  is_error "not JSON" (Sol_cli_json.decode ~what:"x" "{nope");
  is_error
    "required and missing"
    (Sol_cli_json.require ~what:"x" [ "zz" ] Sol_cli_json.int j);
  is_error
    "required, wrong type"
    (Sol_cli_json.require ~what:"x" [ "s" ] Sol_cli_json.int j);
  Alcotest.(check (option string))
    "optional and null"
    None
    (ok "optional" (Sol_cli_json.optional ~what:"x" [ "n" ] Sol_cli_json.string j));
  is_error
    "optional, wrong type"
    (Sol_cli_json.optional ~what:"x" [ "a" ] Sol_cli_json.string j);
  Alcotest.(check int)
    "empty items"
    0
    (List.length (ok "items" (Sol_cli_json.items ~what:"x" {|{"items":[]}|})));
  is_error "no items" (Sol_cli_json.items ~what:"x" {|{"kind":"List"}|});
  is_error "a non-object item" (Sol_cli_json.items ~what:"x" {|{"items":[1]}|})
;;

let test_loki () =
  is_error "no data.result" (Sol_cli_loki.parse_query_range_body {|{"status":"success"}|});
  is_error
    "a value that is not a pair"
    (Sol_cli_loki.parse_query_range_body
       {|{"status":"success","data":{"result":[{"values":[["1"]]}]}}|});
  Alcotest.(check int)
    "an empty result is no lines"
    0
    (List.length
       (ok
          "empty"
          (Sol_cli_loki.parse_query_range_body
             {|{"status":"success","data":{"result":[]}}|})))
;;

let test_disk_quota () =
  is_error
    "a quota without usage"
    (Sol_cli_disk_quota.observation_of_json
       {|{"quotas":[{"metric":"SSD_TOTAL_GB","limit":500.0}]}|});
  let o =
    ok
      "complete"
      (Sol_cli_disk_quota.observation_of_json
         {|{"quotas":[{"metric":"SSD_TOTAL_GB","limit":500.0,"usage":0}]}|})
  in
  Alcotest.(check int) "free" 500 (Sol_cli_disk_quota.free_gb o)
;;

let test_migration_status () =
  is_error
    "an applied entry without a version"
    (Sol_cli_migration.parse_status_json {|{"migrations":[{"applied":true}]}|});
  Alcotest.(check (list int))
    "applied versions only"
    [ 2 ]
    (ok
       "status"
       (Sol_cli_migration.parse_status_json
          {|{"migrations":[{"applied":false,"version":1},{"applied":true,"version":2}]}|}))
;;

let test_release_and_deployment_lists () =
  is_error
    "a release list without items"
    (Sol_cli_release.parse_kubectl_list (`Assoc [ "kind", `String "List" ]));
  Alcotest.(check int)
    "an empty release list"
    0
    (List.length
       (ok "releases" (Sol_cli_release.parse_kubectl_list (`Assoc [ "items", `List [] ]))));
  is_error
    "a deployment list without items"
    (Sol_cli_deployment.parse_kubectl_list (`Assoc [ "kind", `String "List" ]));
  Alcotest.(check int)
    "an empty deployment list"
    0
    (List.length
       (ok
          "deployments"
          (Sol_cli_deployment.parse_kubectl_list (`Assoc [ "items", `List [] ]))))
;;

let () =
  Alcotest.run
    "json boundary"
    [ ( "REFAC-132"
      , [ Alcotest.test_case "the boundary" `Quick test_boundary
        ; Alcotest.test_case "loki query results" `Quick test_loki
        ; Alcotest.test_case "disk quota" `Quick test_disk_quota
        ; Alcotest.test_case "migration status" `Quick test_migration_status
        ; Alcotest.test_case
            "release and deployment lists"
            `Quick
            test_release_and_deployment_lists
        ] )
    ]
;;
