(* REFAC-139: the deploy's migration gate as a library. The in-cluster check
   itself is covered through a fake kubectl in test_migration_job.ml; these pin
   the pure pieces it shares with `sol migrate apply`. *)

let temp_dir () =
  let dir = Filename.temp_file "sol-migration-gate-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir
;;

let write dir name content =
  Out_channel.with_open_bin (Filename.concat dir name) (fun oc ->
    output_string oc content)
;;

let test_files_are_sql_only_and_sorted () =
  let dir = temp_dir () in
  write dir "002_b.sql" "b";
  write dir "001_a.sql" "a";
  write dir "README.md" "not a migration";
  match Sol_cli_migration_gate.migration_files dir with
  | Error e -> Alcotest.fail e
  | Ok files ->
    Alcotest.(check (list (pair string string)))
      "sorted .sql files"
      [ "001_a.sql", "a"; "002_b.sql", "b" ]
      files
;;

let test_nul_is_refused_by_name () =
  let dir = temp_dir () in
  write dir "001_a.sql" "a\000b";
  match Sol_cli_migration_gate.migration_files dir with
  | Ok _ -> Alcotest.fail "expected a NUL character to be refused"
  | Error e ->
    Alcotest.(check bool)
      "names the file"
      true
      (Sol_cli_string.contains ~needle:"001_a.sql" e)
;;

let test_missing_dir_is_an_error () =
  match Sol_cli_migration_gate.migration_files "/nonexistent/sol-migrations" with
  | Ok _ -> Alcotest.fail "expected a missing directory to be an error"
  | Error _ -> ()
;;

let test_registry_override_wins () =
  Alcotest.(check (result string string))
    "override"
    (Ok "override.example")
    (Sol_cli_migration_gate.registry_of
       ~configured:(Some "target.example")
       ~override:(Some "override.example")
       ~how_to_set:"")
;;

let test_registry_absent_says_how_to_set () =
  Alcotest.(check (result string string))
    "absent"
    (Error "no registry configured for this target -- set it.")
    (Sol_cli_migration_gate.registry_of
       ~configured:None
       ~override:None
       ~how_to_set:"set it.")
;;

let () =
  Alcotest.run
    "migration gate"
    [ ( "migration files"
      , [ Alcotest.test_case "sql only, sorted" `Quick test_files_are_sql_only_and_sorted
        ; Alcotest.test_case "NUL refused" `Quick test_nul_is_refused_by_name
        ; Alcotest.test_case "missing dir" `Quick test_missing_dir_is_an_error
        ] )
    ; ( "registry"
      , [ Alcotest.test_case "override wins" `Quick test_registry_override_wins
        ; Alcotest.test_case "absent" `Quick test_registry_absent_says_how_to_set
        ] )
    ]
;;
