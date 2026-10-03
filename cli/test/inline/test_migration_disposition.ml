let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let test_decodes_expand () =
  match
    Sol_cli_migration_disposition.of_file_content
      "-- sol:disposition expand\nALTER TABLE t ADD COLUMN c INT;"
  with
  | Ok Sol_cli_migration_disposition.Expand -> ()
  | Ok Sol_cli_migration_disposition.Contract -> Windtrap.fail "expected Expand"
  | Error msg -> Windtrap.fail msg
;;

let test_decodes_contract () =
  match
    Sol_cli_migration_disposition.of_file_content
      "-- sol:disposition contract\nALTER TABLE t DROP COLUMN c;"
  with
  | Ok Sol_cli_migration_disposition.Contract -> ()
  | Ok Sol_cli_migration_disposition.Expand -> Windtrap.fail "expected Contract"
  | Error msg -> Windtrap.fail msg
;;

let test_tolerates_leading_blank_lines () =
  match
    Sol_cli_migration_disposition.of_file_content
      "\n\n  -- sol:disposition expand  \nSELECT 1;"
  with
  | Ok Sol_cli_migration_disposition.Expand -> ()
  | Ok Sol_cli_migration_disposition.Contract -> Windtrap.fail "expected Expand"
  | Error msg -> Windtrap.fail msg
;;

let test_missing_header_fails_closed () =
  match Sol_cli_migration_disposition.of_file_content "CREATE TABLE t (id INT);" with
  | Ok _ -> Windtrap.fail "expected Error on a missing header"
  | Error msg ->
    assert (Sol_cli_string.contains ~needle:"missing a sol:disposition header" msg)
;;

let test_empty_file_fails_closed () =
  match Sol_cli_migration_disposition.of_file_content "" with
  | Ok _ -> Windtrap.fail "expected Error on an empty file"
  | Error msg ->
    assert (Sol_cli_string.contains ~needle:"missing a sol:disposition header" msg)
;;

let test_malformed_value_fails_closed () =
  match
    Sol_cli_migration_disposition.of_file_content "-- sol:disposition sideways\nSELECT 1;"
  with
  | Ok _ -> Windtrap.fail "expected Error on an unrecognised disposition value"
  | Error msg ->
    assert (Sol_cli_string.contains ~needle:"malformed sol:disposition header" msg);
    assert (Sol_cli_string.contains ~needle:"sideways" msg)
;;

let test_late_mention_is_not_the_header () =
  match
    Sol_cli_migration_disposition.of_file_content
      "-- a plain comment\n-- sol:disposition expand\nSELECT 1;"
  with
  | Ok _ -> Windtrap.fail "expected Error: the tag was not the first non-blank line"
  | Error msg ->
    assert (Sol_cli_string.contains ~needle:"missing a sol:disposition header" msg)
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
       | Ok Sol_cli_migration_disposition.Expand -> Windtrap.fail "expected Contract"
       | Error msg -> Windtrap.fail msg)
;;

let test_read_file_missing_path () =
  match
    Sol_cli_migration_disposition.read_file ~path:"/nonexistent/does-not-exist.sql"
  with
  | Ok _ -> Windtrap.fail "expected Error for a nonexistent file"
  | Error msg -> assert (Sol_cli_string.contains ~needle:"could not read" msg)
;;

let test_to_string () =
  check_string "expand" "expand" (Sol_cli_migration_disposition.to_string Expand);
  check_string "contract" "contract" (Sol_cli_migration_disposition.to_string Contract)
;;

let%test "decode: expand" = test_decodes_expand ()
let%test "decode: contract" = test_decodes_contract ()
let%test "decode: tolerates leading blank lines" = test_tolerates_leading_blank_lines ()
let%test "decode: missing header fails closed" = test_missing_header_fails_closed ()
let%test "decode: empty file fails closed" = test_empty_file_fails_closed ()
let%test "decode: malformed value fails closed" = test_malformed_value_fails_closed ()
let%test "decode: late mention is not the header" = test_late_mention_is_not_the_header ()
let%test "read_file: round-trips a written file" = test_read_file_roundtrip ()
let%test "read_file: missing path fails closed" = test_read_file_missing_path ()
let%test "read_file: renders both variants" = test_to_string ()
