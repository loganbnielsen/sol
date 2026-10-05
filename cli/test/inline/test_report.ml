let level_name = function
  | Logs.App -> "app"
  | Logs.Warning -> "warning"
  | Logs.Error -> "error"
  | Logs.Info -> "info"
  | Logs.Debug -> "debug"
;;

let test_levels () =
  let (), reported =
    Sol_cli_report.collect (fun () ->
      Sol_cli_report.app "progress %d" 1;
      Sol_cli_report.warn "warning: %s" "careful";
      Sol_cli_report.err "error: %S" "bad";
      Sol_cli_report.app_block "a block\n")
  in
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"each report, at its level, in order, with no doubled newline"
    [ "app", "progress 1"
    ; "warning", "warning: careful"
    ; "error", {|error: "bad"|}
    ; "app", "a block"
    ]
    (List.map (fun (level, text) -> level_name level, text) reported)
;;

let test_scan_non_directory_is_an_error () =
  let root = Filename.temp_dir "sol-report-" "" in
  let events = Filename.concat root "events" in
  let oc = open_out events in
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      Sys.remove events;
      Unix.rmdir root)
    (fun () ->
       match Sol_cli_workspace_scan.discover_schema_subjects ~root () with
       | Error message ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"names the non-directory events path"
           true
           (Sol_cli_string.contains ~needle:"events" message)
       | Ok _ -> Windtrap.fail "a non-directory events path must not load as empty")
;;

let test_scan_unreadable_subdirectory_is_an_error () =
  if Unix.geteuid () = 0
  then ()
  else (
    let root = Filename.temp_dir "sol-report-" "" in
    let domain = Filename.concat (Filename.concat root "events") "payments" in
    Unix.mkdir (Filename.concat root "events") 0o755;
    Unix.mkdir domain 0o000;
    Fun.protect
      ~finally:(fun () ->
        Unix.chmod domain 0o755;
        Unix.rmdir domain;
        Unix.rmdir (Filename.concat root "events");
        Unix.rmdir root)
      (fun () ->
         match Sol_cli_workspace_scan.discover_schema_subjects ~root () with
         | Error message ->
           Windtrap.equal
             Windtrap.bool
             ~msg:"names the unreadable directory"
             true
             (Sol_cli_string.contains ~needle:"payments" message)
         | Ok _ ->
           Windtrap.fail "an unreadable declaration directory must not load as empty"))
;;

let%test "REFAC-135: levels and order" = test_levels ()
let%test "a non-directory events path is refused" = test_scan_non_directory_is_an_error ()

let%test "an unreadable declaration directory is refused" =
  test_scan_unreadable_subdirectory_is_an_error ()
;;
