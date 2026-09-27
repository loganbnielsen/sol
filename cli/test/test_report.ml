(* REFAC-135: library code reports; it does not print. These hold that a report
   reaches whoever installed the reporter, at its level, and that a warning which
   used to be printed and dropped is now something a caller can see. *)

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
  Alcotest.(check (list (pair string string)))
    "each report, at its level, in order, with no doubled newline"
    [ "app", "progress 1"
    ; "warning", "warning: careful"
    ; "error", {|error: "bad"|}
    ; "app", "a block"
    ]
    (List.map (fun (level, text) -> level_name level, text) reported)
;;

(* The workspace scan's unreadable-directory warning used to go straight to
   stderr, so nothing could assert on it. *)
let test_scan_warning_is_reported () =
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
       let _, reported =
         Sol_cli_report.collect (fun () ->
           Sol_cli_workspace_scan.discover_schema_subjects ~root ())
       in
       match reported with
       | [ (Logs.Warning, text) ] ->
         Alcotest.(check bool)
           "names the unreadable directory"
           true
           (Sol_cli_string.contains ~needle:"payments" text)
       | other ->
         Alcotest.failf
           "expected one warning, got: %s"
           (other |> List.map snd |> String.concat " | "))
;;

let () =
  Alcotest.run
    "report"
    [ ( "REFAC-135"
      , [ Alcotest.test_case "levels and order" `Quick test_levels
        ; Alcotest.test_case
            "a scan warning is reported"
            `Quick
            test_scan_warning_is_reported
        ] )
    ]
;;
