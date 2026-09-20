(* AUDIT-069: the pure migration prerequisite -- required (db/migrations) ⊆
   applied (schema_migrations) -- and the JSON encoding the read-only status Job
   and the deploy path share. *)

module M = Sol_cli_migration

let contains haystack needle =
  let re = Str.regexp_string needle in
  try
    ignore (Str.search_forward re haystack 0);
    true
  with
  | Not_found -> false
;;

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
      Array.iter
        (fun entry ->
           try Sys.remove (Filename.concat dir entry) with
           | _ -> ())
        (Sys.readdir dir);
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

let test_required_missing_dir_is_empty () =
  Alcotest.(check bool)
    "a workspace with no migrations requires nothing"
    true
    (match M.required ~dir:"/nonexistent/migrations" with
     | Ok [] -> true
     | _ -> false)
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

(* INFRA-040: the deploy's migration gate removes its Job, so a failure has to be
   reported out of it. Attempt 6's message said "see the Job logs" after the Job
   was gone, and the cause had to be rediscovered with a different command. *)

let test_evidence_report_unstartable_names_the_reason () =
  let report =
    M.evidence_report
      ~waiting:(Some ("CreateContainerConfigError", "secret \"sol-secrets\" not found"))
      ~logs:""
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
    M.evidence_report ~waiting:None ~logs:"error: migration 003 failed\nline two"
  in
  Alcotest.(check bool) "first line" true (contains report "migration 003 failed");
  Alcotest.(check bool) "second line" true (contains report "line two");
  Alcotest.(check bool)
    "no waiting section is invented"
    false
    (contains report "container waiting")
;;

let test_evidence_report_carries_both () =
  let report = M.evidence_report ~waiting:(Some ("CrashLoopBackOff", "")) ~logs:"boom" in
  Alcotest.(check bool) "reason" true (contains report "CrashLoopBackOff");
  Alcotest.(check bool) "logs" true (contains report "boom")
;;

let test_evidence_report_is_empty_without_observations () =
  Alcotest.(check string) "no observations" "" (M.evidence_report ~waiting:None ~logs:"");
  Alcotest.(check string)
    "blank logs are not an observation"
    ""
    (M.evidence_report ~waiting:None ~logs:"   \n")
;;

let () =
  Alcotest.run
    "migration"
    [ ( "prerequisite"
      , [ Alcotest.test_case "table name" `Quick test_table_name
        ; Alcotest.test_case "parse version" `Quick test_parse_version
        ; Alcotest.test_case "required set" `Quick test_required
        ; Alcotest.test_case
            "unnumbered migration is an error"
            `Quick
            test_required_rejects_unnumbered
        ; Alcotest.test_case
            "missing directory requires nothing"
            `Quick
            test_required_missing_dir_is_empty
        ; Alcotest.test_case "unsatisfied subset" `Quick test_unsatisfied
        ] )
    ; ( "encoding"
      , [ Alcotest.test_case "parse status json" `Quick test_parse_status_json
        ; Alcotest.test_case "status json round-trip" `Quick test_status_json_roundtrip
        ] )
    ; ( "connection redaction"
      , [ Alcotest.test_case
            "runner error hides password"
            `Quick
            test_runner_error_redacts_password_and_keeps_shape
        ; Alcotest.test_case
            "Job logs hide every password occurrence"
            `Quick
            test_job_log_boundary_redacts_repeated_secret_values
        ; Alcotest.test_case
            "non-credential inputs unchanged"
            `Quick
            test_passwordless_and_non_uri_inputs_are_unchanged
        ] )
    ; ( "failure evidence (INFRA-040)"
      , [ Alcotest.test_case
            "unstartable Job names its reason"
            `Quick
            test_evidence_report_unstartable_names_the_reason
        ; Alcotest.test_case
            "failed Job carries its logs"
            `Quick
            test_evidence_report_failed_job_carries_its_logs
        ; Alcotest.test_case
            "both observations together"
            `Quick
            test_evidence_report_carries_both
        ; Alcotest.test_case
            "nothing observed, nothing reported"
            `Quick
            test_evidence_report_is_empty_without_observations
        ] )
    ]
;;
