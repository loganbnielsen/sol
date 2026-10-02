module M = Sol_cli_migration

let contains haystack needle = Sol_cli_string.contains ~needle haystack

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let with_tmp_dir f =
  let dir = Filename.temp_file "sol-migration-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.readdir dir
      |> Array.iter (fun entry ->
        try Sys.remove (Filename.concat dir entry) with
        | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () -> f dir)
;;

let test_table_name () =
  Alcotest.(check string)
    "per-workspace, same naming as sol migrate"
    "sol_pluto_schema_migrations"
    (M.table_name ~workspace:"pluto");
  Alcotest.(check string)
    "punctuation becomes an underscore"
    "sol_my_ws_schema_migrations"
    (M.table_name ~workspace:"My-WS")
;;

let test_table_name_is_bounded () =
  let at_limit = String.make 41 'a' in
  let over_limit = String.make 42 'a' in
  Alcotest.(check string)
    "a name that lands exactly on the limit keeps the readable form"
    (Printf.sprintf "sol_%s_schema_migrations" at_limit)
    (M.table_name ~workspace:at_limit);
  let shortened = M.table_name ~workspace:over_limit in
  Alcotest.(check bool)
    "one byte past the limit is shortened"
    true
    (String.length shortened <= M.postgres_identifier_max_bytes && shortened <> over_limit);
  List.iter
    (fun workspace ->
       let table = M.table_name ~workspace in
       Alcotest.(check bool)
         (Printf.sprintf
            "a %d-byte workspace name stays within the identifier limit"
            (String.length workspace))
         true
         (String.length table <= M.postgres_identifier_max_bytes))
    [ ""; "pluto"; String.make 300 'a'; "wörk"; "My-WS"; over_limit ]
;;

let test_long_workspace_names_stay_distinct () =
  let table workspace = M.table_name ~workspace in
  let fifty_nine suffix = String.make 59 'a' ^ suffix in
  let fifty_eight suffix = String.make 58 'a' ^ suffix in
  Alcotest.(check bool)
    "two 60-byte workspace names no longer share a truncated table"
    true
    (String.compare (table (fifty_nine "x")) (table (fifty_nine "y")) <> 0);
  Alcotest.(check bool)
    "the 59-byte control stays distinct too"
    true
    (String.compare (table (fifty_eight "x")) (table (fifty_eight "y")) <> 0);
  Alcotest.(check string)
    "the shortened name is stable across calls"
    (table (fifty_nine "x"))
    (table (fifty_nine "x"))
;;

let test_table_length_error () =
  Alcotest.(check (option string))
    "a normal override is accepted"
    None
    (M.table_length_error ~table:"sol_pluto_schema_migrations");
  Alcotest.(check (option string))
    "an override exactly on the limit is accepted"
    None
    (M.table_length_error ~table:(String.make M.postgres_identifier_max_bytes 'a'));
  Alcotest.(check bool)
    "an override PostgreSQL would truncate is refused"
    true
    (Option.is_some
       (M.table_length_error
          ~table:(String.make (M.postgres_identifier_max_bytes + 1) 'a')))
;;

let test_parse_version () =
  let check = Alcotest.(check @@ option @@ pair int string) in
  check "standard" (Some (1, "create_orders")) (M.parse_version "001_create_orders.sql");
  check "no underscore" None (M.parse_version "0001.sql");
  check "non-numeric" None (M.parse_version "init_db.sql")
;;

let test_required () =
  with_tmp_dir (fun dir ->
    write_file (Filename.concat dir "002_add_index.sql") "";
    write_file (Filename.concat dir "001_create_orders.sql") "";
    write_file (Filename.concat dir "notes.md") "";
    match M.required ~dir with
    | Error e -> Alcotest.fail e
    | Ok required ->
      Alcotest.(check (list string))
        "every .sql, ordered by version"
        [ "001_create_orders"; "002_add_index" ]
        (List.map M.to_string required))
;;

let test_required_rejects_unnumbered () =
  with_tmp_dir (fun dir ->
    write_file (Filename.concat dir "init_db.sql") "";
    match M.required ~dir with
    | Ok _ -> Alcotest.fail "expected an error for a migration without a version"
    | Error msg ->
      Alcotest.(check bool) "names the offending file" true (contains msg "init_db.sql"))
;;

let test_required_rejects_a_shared_version () =
  with_tmp_dir (fun dir ->
    write_file (Filename.concat dir "001_create_orders.sql") "";
    write_file (Filename.concat dir "004_add_refunds.sql") "";
    write_file (Filename.concat dir "004_add_invoices.sql") "";
    match M.required ~dir with
    | Ok _ -> Alcotest.fail "expected an error for two migrations sharing version 4"
    | Error msg ->
      Alcotest.(check bool) "names first file" true (contains msg "004_add_invoices.sql");
      Alcotest.(check bool) "names second file" true (contains msg "004_add_refunds.sql"))
;;

let test_shared_version_names_four_digit_files () =
  with_tmp_dir (fun dir ->
    write_file (Filename.concat dir "0004_a.sql") "";
    write_file (Filename.concat dir "0004_b.sql") "";
    match M.required ~dir with
    | Ok _ -> Alcotest.fail "expected an error for two migrations sharing version 4"
    | Error msg ->
      Alcotest.(check bool) "names first file" true (contains msg "0004_a.sql");
      Alcotest.(check bool) "names second file" true (contains msg "0004_b.sql"))
;;

let test_required_ignores_down_files () =
  with_tmp_dir (fun dir ->
    write_file (Filename.concat dir "001_create_orders.sql") "";
    write_file (Filename.concat dir "001_create_orders.down.sql") "";
    match M.required ~dir with
    | Error e -> Alcotest.fail e
    | Ok required ->
      Alcotest.(check (list string))
        "the down file is not a required migration"
        [ "001_create_orders" ]
        (List.map M.to_string required))
;;

let test_required_missing_dir_is_an_error () =
  match M.required ~dir:"/nonexistent/migrations" with
  | Ok _ -> Alcotest.fail "expected a missing migrations directory to be refused"
  | Error message ->
    Alcotest.(check bool)
      "names the path"
      true
      (contains message "/nonexistent/migrations")
;;

let test_required_if_present_missing_dir_is_empty () =
  Alcotest.(check bool)
    "a workspace with no migrations requires nothing"
    true
    (match M.required_if_present ~dir:"/nonexistent/migrations" with
     | Ok [] -> true
     | _ -> false)
;;

let test_required_file_instead_of_dir_is_an_error () =
  with_tmp_dir (fun dir ->
    let path = Filename.concat dir "db-migrations" in
    write_file path "";
    match M.required ~dir:path with
    | Ok _ -> Alcotest.fail "expected a regular file at the migrations path to be refused"
    | Error message ->
      Alcotest.(check bool) "names the distinct path" true (contains message path))
;;

let test_required_unreadable_dir_is_an_error () =
  with_tmp_dir (fun dir ->
    Unix.chmod dir 0o000;
    Fun.protect
      ~finally:(fun () -> Unix.chmod dir 0o755)
      (fun () ->
         if Unix.geteuid () = 0
         then ()
         else (
           match M.required ~dir with
           | Ok _ ->
             Alcotest.fail "expected an unreadable migrations directory to be refused"
           | Error message ->
             Alcotest.(check bool) "names the path" true (contains message dir))))
;;

let test_unsatisfied () =
  let required : M.prerequisite list =
    [ { version = 1; name = "a" }; { version = 2; name = "b" } ]
  in
  Alcotest.(check (list string))
    "the unapplied one is missing"
    [ "002_b" ]
    (List.map M.to_string (M.unsatisfied ~required ~applied:[ 1 ]));
  Alcotest.(check (list string))
    "a superset is satisfied"
    []
    (List.map M.to_string (M.unsatisfied ~required ~applied:[ 1; 2; 3 ]));
  Alcotest.(check (list string))
    "nothing applied means everything is missing"
    [ "001_a"; "002_b" ]
    (List.map M.to_string (M.unsatisfied ~required ~applied:[]))
;;

let test_parse_status_json () =
  let body =
    {|{"table":"sol_pluto_schema_migrations","migrations":[{"version":1,"name":"a","applied":true,"applied_at":"2026-01-01T00:00:00Z"},{"version":2,"name":"b","applied":false,"applied_at":null}]}|}
  in
  Alcotest.(check (list int))
    "only the applied versions"
    [ 1 ]
    (match M.parse_status_json body with
     | Ok v -> v
     | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    "malformed input is an error"
    true
    (match M.parse_status_json "not json" with
     | Error _ -> true
     | Ok _ -> false);
  Alcotest.(check bool)
    "a report without the migrations array is an error"
    true
    (match M.parse_status_json {|{"table":"t"}|} with
     | Error _ -> true
     | Ok _ -> false)
;;

let test_status_json_roundtrip () =
  let body =
    M.status_json ~table:"t" [ 1, "a", Some "2026-01-01T00:00:00Z"; 2, "b", None ]
  in
  Alcotest.(check (list int))
    "the writer and reader share one encoding"
    [ 1 ]
    (match M.parse_status_json body with
     | Ok v -> v
     | Error e -> Alcotest.fail e);
  Alcotest.(check bool) "carries the table" true (contains body "\"table\":\"t\"")
;;

let connection_url =
  "postgresql://postgres:known-password@db.internal:5432/app?sslmode=require"
;;

let test_runner_error_redacts_password_and_keeps_shape () =
  let raw = "create migrations table: Failed to connect to <" ^ connection_url ^ ">" in
  let rendered = Sol_cli_redaction.connection_error ~url:connection_url raw in
  Alcotest.(check bool) "password absent" false (contains rendered "known-password");
  Alcotest.(check bool)
    "placeholder present"
    true
    (contains rendered "postgres:<redacted>@");
  Alcotest.(check bool)
    "host and database remain"
    true
    (contains rendered "db.internal:5432/app")
;;

let test_job_log_boundary_redacts_repeated_secret_values () =
  let raw =
    "migration error: " ^ connection_url ^ "\nretry failed; password=known-password\n"
  in
  let rendered = Sol_cli_redaction.connection_error ~url:connection_url raw in
  Alcotest.(check bool)
    "password absent everywhere"
    false
    (contains rendered "known-password");
  Alcotest.(check bool) "diagnosis retained" true (contains rendered "retry failed")
;;

let test_passwordless_and_non_uri_inputs_are_unchanged () =
  Alcotest.(check string)
    "passwordless"
    "connection refused"
    (Sol_cli_redaction.connection_error
       ~url:"postgresql://db.internal/app"
       "connection refused");
  Alcotest.(check string)
    "not a URI"
    "bad input"
    (Sol_cli_redaction.connection_error ~url:"opaque" "bad input")
;;

let test_evidence_report_unstartable_names_the_reason () =
  let report =
    M.evidence_report
      ~waiting:
        (Some ("CreateContainerConfigError", Some "secret \"sol-secrets\" not found"))
      ~logs:None
    |> Option.get
  in
  Alcotest.(check bool)
    "waiting reason"
    true
    (contains report "CreateContainerConfigError");
  Alcotest.(check bool)
    "waiting message"
    true
    (contains report "secret \"sol-secrets\" not found");
  Alcotest.(check bool)
    "no empty logs section is invented"
    false
    (contains report "job logs:")
;;

let test_evidence_report_failed_job_carries_its_logs () =
  let report =
    M.evidence_report ~waiting:None ~logs:(Some "error: migration 003 failed\nline two")
    |> Option.get
  in
  Alcotest.(check bool) "first line" true (contains report "migration 003 failed");
  Alcotest.(check bool) "second line" true (contains report "line two");
  Alcotest.(check bool)
    "no waiting section is invented"
    false
    (contains report "container waiting")
;;

let test_evidence_report_carries_both () =
  let report =
    M.evidence_report ~waiting:(Some ("CrashLoopBackOff", None)) ~logs:(Some "boom")
    |> Option.get
  in
  Alcotest.(check bool) "reason" true (contains report "CrashLoopBackOff");
  Alcotest.(check bool) "logs" true (contains report "boom")
;;

let test_evidence_report_is_empty_without_observations () =
  Alcotest.(check bool)
    "no observations, no report"
    true
    (M.evidence_report ~waiting:None ~logs:None = None)
;;

let%test "prerequisite: table name" = test_table_name ()
let%test "prerequisite: table name stays bounded" = test_table_name_is_bounded ()

let%test "prerequisite: long workspace names stay distinct" =
  test_long_workspace_names_stay_distinct ()
;;

let%test "prerequisite: table override length" = test_table_length_error ()
let%test "prerequisite: parse version" = test_parse_version ()
let%test "prerequisite: required set" = test_required ()

let%test "prerequisite: unnumbered migration is an error" =
  test_required_rejects_unnumbered ()
;;

let%test "prerequisite: shared version is an error" =
  test_required_rejects_a_shared_version ()
;;

let%test "prerequisite: down files are not migrations" =
  test_required_ignores_down_files ()
;;

let%test "prerequisite: shared version names four-digit files" =
  test_shared_version_names_four_digit_files ()
;;

let%test "prerequisite: missing directory is an error" =
  test_required_missing_dir_is_an_error ()
;;

let%test "prerequisite: missing directory requires nothing when absence is allowed" =
  test_required_if_present_missing_dir_is_empty ()
;;

let%test "prerequisite: a file at the migrations path is an error (BUG-082)" =
  test_required_file_instead_of_dir_is_an_error ()
;;

let%test "prerequisite: an unreadable migrations directory is an error (BUG-082)" =
  test_required_unreadable_dir_is_an_error ()
;;

let%test "prerequisite: unsatisfied subset" = test_unsatisfied ()
let%test "encoding: parse status json" = test_parse_status_json ()
let%test "encoding: status json round-trip" = test_status_json_roundtrip ()

let%test "connection redaction: runner error hides password" =
  test_runner_error_redacts_password_and_keeps_shape ()
;;

let%test "connection redaction: Job logs hide every password occurrence" =
  test_job_log_boundary_redacts_repeated_secret_values ()
;;

let%test "connection redaction: non-credential inputs unchanged" =
  test_passwordless_and_non_uri_inputs_are_unchanged ()
;;

let%test "failure evidence (INFRA-040): unstartable Job names its reason" =
  test_evidence_report_unstartable_names_the_reason ()
;;

let%test "failure evidence (INFRA-040): failed Job carries its logs" =
  test_evidence_report_failed_job_carries_its_logs ()
;;

let%test "failure evidence (INFRA-040): both observations together" =
  test_evidence_report_carries_both ()
;;

let%test "failure evidence (INFRA-040): nothing observed, nothing reported" =
  test_evidence_report_is_empty_without_observations ()
;;
