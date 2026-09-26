let check_string = Alcotest.(check string)
let contains needle haystack = Sol_cli_string.contains ~needle haystack

let test_decodes_expand () =
  match
    Sol_cli_migration_disposition.of_file_content
      "-- sol:disposition expand\nALTER TABLE t ADD COLUMN c INT;"
  with
  | Ok Sol_cli_migration_disposition.Expand -> ()
  | Ok Sol_cli_migration_disposition.Contract -> Alcotest.fail "expected Expand"
  | Error msg -> Alcotest.fail msg
;;

let test_decodes_contract () =
  match
    Sol_cli_migration_disposition.of_file_content
      "-- sol:disposition contract\nALTER TABLE t DROP COLUMN c;"
  with
  | Ok Sol_cli_migration_disposition.Contract -> ()
  | Ok Sol_cli_migration_disposition.Expand -> Alcotest.fail "expected Contract"
  | Error msg -> Alcotest.fail msg
;;

let test_tolerates_leading_blank_lines () =
  match
    Sol_cli_migration_disposition.of_file_content
      "\n\n  -- sol:disposition expand  \nSELECT 1;"
  with
  | Ok Sol_cli_migration_disposition.Expand -> ()
  | Ok Sol_cli_migration_disposition.Contract -> Alcotest.fail "expected Expand"
  | Error msg -> Alcotest.fail msg
;;

let test_missing_header_fails_closed () =
  match Sol_cli_migration_disposition.of_file_content "CREATE TABLE t (id INT);" with
  | Ok _ -> Alcotest.fail "expected Error on a missing header"
  | Error msg -> assert (contains "missing a sol:disposition header" msg)
;;

let test_empty_file_fails_closed () =
  match Sol_cli_migration_disposition.of_file_content "" with
  | Ok _ -> Alcotest.fail "expected Error on an empty file"
  | Error msg -> assert (contains "missing a sol:disposition header" msg)
;;

let test_malformed_value_fails_closed () =
  match
    Sol_cli_migration_disposition.of_file_content "-- sol:disposition sideways\nSELECT 1;"
  with
  | Ok _ -> Alcotest.fail "expected Error on an unrecognised disposition value"
  | Error msg ->
    assert (contains "malformed sol:disposition header" msg);
    assert (contains "sideways" msg)
;;

(* Not a substring search: a mention later in the file must not be mistaken
   for the authored header. *)
let test_late_mention_is_not_the_header () =
  match
    Sol_cli_migration_disposition.of_file_content
      "-- a plain comment\n-- sol:disposition expand\nSELECT 1;"
  with
  | Ok _ -> Alcotest.fail "expected Error: the tag was not the first non-blank line"
  | Error msg -> assert (contains "missing a sol:disposition header" msg)
;;

let test_read_file_roundtrip () =
  let path = Filename.temp_file "sol-migration-" ".sql" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
       let oc = open_out path in
       output_string oc "-- sol:disposition contract\nALTER TABLE t DROP COLUMN c;";
       close_out oc;
       match Sol_cli_migration_disposition.read_file ~path with
       | Ok Sol_cli_migration_disposition.Contract -> ()
       | Ok Sol_cli_migration_disposition.Expand -> Alcotest.fail "expected Contract"
       | Error msg -> Alcotest.fail msg)
;;

let test_read_file_missing_path () =
  match
    Sol_cli_migration_disposition.read_file ~path:"/nonexistent/does-not-exist.sql"
  with
  | Ok _ -> Alcotest.fail "expected Error for a nonexistent file"
  | Error msg -> assert (contains "could not read" msg)
;;

let test_to_string () =
  check_string "expand" "expand" (Sol_cli_migration_disposition.to_string Expand);
  check_string "contract" "contract" (Sol_cli_migration_disposition.to_string Contract)
;;

let () =
  Alcotest.run
    "migration_disposition"
    [ ( "decode"
      , [ Alcotest.test_case "expand" `Quick test_decodes_expand
        ; Alcotest.test_case "contract" `Quick test_decodes_contract
        ; Alcotest.test_case
            "tolerates leading blank lines"
            `Quick
            test_tolerates_leading_blank_lines
        ; Alcotest.test_case
            "missing header fails closed"
            `Quick
            test_missing_header_fails_closed
        ; Alcotest.test_case "empty file fails closed" `Quick test_empty_file_fails_closed
        ; Alcotest.test_case
            "malformed value fails closed"
            `Quick
            test_malformed_value_fails_closed
        ; Alcotest.test_case
            "late mention is not the header"
            `Quick
            test_late_mention_is_not_the_header
        ] )
    ; ( "read_file"
      , [ Alcotest.test_case "round-trips a written file" `Quick test_read_file_roundtrip
        ; Alcotest.test_case
            "missing path fails closed"
            `Quick
            test_read_file_missing_path
        ] )
    ; "to_string", [ Alcotest.test_case "renders both variants" `Quick test_to_string ]
    ]
;;
