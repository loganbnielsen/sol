let fixture_path () =
  [ "../fixtures/terraform-output-gcp-cloud.json"
  ; "fixtures/terraform-output-gcp-cloud.json"
  ; "cli/test/fixtures/terraform-output-gcp-cloud.json"
  ]
  |> List.find_opt Sys.file_exists
  |> Option.value ~default:"../fixtures/terraform-output-gcp-cloud.json"
;;

let read_fixture () =
  let ic = open_in_bin (fixture_path ()) in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let test_reads_the_payload_terraform_produced () =
  match Sol_cli_gcp_cluster.project_id_of_outputs_json (read_fixture ()) with
  | Error message -> Alcotest.failf "the captured payload was refused: %s" message
  | Ok project ->
    Alcotest.(check string) "the project Terraform published" "sol-qualification" project
;;

let test_every_fixture_entry_carries_the_wrapper () =
  match Yojson.Safe.from_string (read_fixture ()) with
  | `Assoc outputs ->
    Alcotest.(check bool) "the fixture is a non-empty object" true (outputs <> []);
    List.iter
      (fun (name, entry) ->
         let keys =
           match entry with
           | `Assoc fields -> List.map fst fields
           | _ -> []
         in
         Alcotest.(check (list string))
           (Printf.sprintf "%s carries terraform's own fields" name)
           [ "sensitive"; "type"; "value" ]
           (List.sort compare keys))
      outputs
  | _ -> Alcotest.fail "the fixture is not an object"
;;

let test_malformed_and_absent_payloads_refuse () =
  let refuse label payload =
    match Sol_cli_gcp_cluster.project_id_of_outputs_json payload with
    | Ok project -> Alcotest.failf "%s was accepted as %s" label project
    | Error _ -> ()
  in
  refuse "an empty object" "{}";
  refuse "invalid JSON" "not json";
  refuse "truncated JSON" {|{"project_id":{"value":|};
  refuse
    "a missing project_id"
    {|{"cluster_name":{"value":"c","type":"string","sensitive":false}}|};
  refuse "a null project_id" {|{"project_id":null}|};
  refuse
    "a null value"
    {|{"project_id":{"value":null,"type":"string","sensitive":false}}|};
  refuse
    "a non-string value"
    {|{"project_id":{"value":42,"type":"number","sensitive":false}}|};
  refuse
    "a blank value"
    {|{"project_id":{"value":"   ","type":"string","sensitive":false}}|}
;;

let%test "project_id: reads the payload terraform produced" =
  test_reads_the_payload_terraform_produced ()
;;

let%test "project_id: every fixture entry carries terraform's own fields" =
  test_every_fixture_entry_carries_the_wrapper ()
;;

let%test "project_id: malformed, absent and non-string payloads refuse" =
  test_malformed_and_absent_payloads_refuse ()
;;
