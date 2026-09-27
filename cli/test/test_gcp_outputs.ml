(* INFRA-091 / FND-0063: Sol consumes `terraform output -json`, so the test that says it can must
   read a payload Terraform produced. The fixture beside this file is that payload: the eight
   outputs GCP qualification Attempt 13 recorded in its captured state, rendered by terraform
   1.9.8 into `terraform output -json` form. `internal/ci/check_terraform_output_fixture.sh`
   checks its shape and that the lifecycle harness serves this same payload rather than a shape of
   its own.

   Attempt 13's parser read a bare string or a single-field `{"value": ...}` object; neither is
   something Terraform emits, so every real run refused while this suite, fed the invented shape,
   passed. The cases below are therefore anchored on the fixture, and the refusals are the ones
   that must stay refusals: absent, blank, malformed and non-string. *)

let fixture_path () =
  (* dune runs this beside the copied fixture; a direct `dune exec` starts at the repository
     root, which is the same file reached through the source path. *)
  [ "fixtures/terraform-output-gcp-cloud.json"
  ; "cli/test/fixtures/terraform-output-gcp-cloud.json"
  ]
  |> List.find_opt Sys.file_exists
  |> Option.value ~default:"fixtures/terraform-output-gcp-cloud.json"
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
  (* A statement about the world, not about the parser: this is what Terraform publishes. *)
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

let () =
  Alcotest.run
    "gcp_outputs"
    [ ( "project_id"
      , [ Alcotest.test_case
            "reads the payload terraform produced"
            `Quick
            test_reads_the_payload_terraform_produced
        ; Alcotest.test_case
            "every fixture entry carries terraform's own fields"
            `Quick
            test_every_fixture_entry_carries_the_wrapper
        ; Alcotest.test_case
            "malformed, absent and non-string payloads refuse"
            `Quick
            test_malformed_and_absent_payloads_refuse
        ] )
    ]
;;
