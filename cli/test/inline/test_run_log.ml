let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)

module R = Sol_cli_run_log

let test_generate_run_id_format () =
  let id = R.generate_run_id ~prefix:"cloud-apply" ~now:1_700_000_000.0 ~pid:4242 in
  check_bool
    "starts with prefix"
    true
    (String.length id >= String.length "cloud-apply-"
     && String.sub id 0 (String.length "cloud-apply-") = "cloud-apply-")
;;

let test_generate_run_id_ends_with_pid () =
  let id = R.generate_run_id ~prefix:"x" ~now:1_700_000_000.0 ~pid:4242 in
  check_bool
    "ends with pid"
    true
    (try
       ignore (Str.search_forward (Str.regexp_string "-4242") id 0);
       true
     with
     | Not_found -> false)
;;

let test_generate_run_id_deterministic () =
  let a = R.generate_run_id ~prefix:"x" ~now:1_700_000_000.0 ~pid:1 in
  let b = R.generate_run_id ~prefix:"x" ~now:1_700_000_000.0 ~pid:1 in
  check_string "same inputs -> same id" a b
;;

let test_tail_lines_shorter_than_n () =
  check_string "returns input unchanged" "a\nb" (R.tail_lines ~n:10 "a\nb")
;;

let test_tail_lines_longer_than_n () =
  let s = String.concat "\n" (List.init 100 string_of_int) in
  let tailed = R.tail_lines ~n:3 s in
  check_string "last 3 lines" "97\n98\n99" tailed
;;

let test_phase_log_content_no_stderr () =
  check_string "just stdout" "hello" (R.phase_log_content ~stdout:"hello" ~stderr:"")
;;

let test_phase_log_content_with_stderr () =
  let content = R.phase_log_content ~stdout:"out" ~stderr:"err" in
  check_bool
    "contains stdout"
    true
    (try
       ignore (Str.search_forward (Str.regexp_string "out") content 0);
       true
     with
     | Not_found -> false);
  check_bool
    "contains stderr"
    true
    (try
       ignore (Str.search_forward (Str.regexp_string "err") content 0);
       true
     with
     | Not_found -> false)
;;

let test_format_phase_line_ok () =
  check_string
    "ok line"
    "[terraform-init] ok (1.5s)"
    (R.format_phase_line ~name:"terraform-init" ~elapsed_s:1.5 ~ok:true)
;;

let test_format_phase_line_failed () =
  check_string
    "failed line"
    "[terraform-apply] FAILED (0.3s)"
    (R.format_phase_line ~name:"terraform-apply" ~elapsed_s:0.3 ~ok:false)
;;

let contains needle haystack = Sol_cli_string.contains ~needle haystack

let test_format_failure_report_names_run_and_log () =
  let report =
    R.format_failure_report
      ~run_id:"deploy-20260101T000000Z-1"
      ~log_path:"/tmp/runs/apply.log"
      ~tail:"boom"
  in
  check_bool "names the run id" true (contains "deploy-20260101T000000Z-1" report);
  check_bool "names the log path" true (contains "/tmp/runs/apply.log" report);
  check_bool "includes the tail" true (contains "boom" report)
;;

let test_runs_to_prune_under_limit () =
  check_int
    "nothing to prune"
    0
    (List.length (R.runs_to_prune ~all_run_ids:[ "a-1"; "a-2" ] ~keep:20 ()))
;;

let test_runs_to_prune_orders_by_timestamp_across_prefixes () =
  let older = List.init 20 (fun i -> Printf.sprintf "deploy-20260917T1911%02dZ-1" i) in
  let fresh = "cloud-apply-20260917T205351Z-20714" in
  let pruned = R.runs_to_prune ~all_run_ids:(older @ [ fresh ]) ~keep:20 () in
  check_int "prunes exactly the overflow" 1 (List.length pruned);
  check_bool "never prunes the newest run" false (List.mem fresh pruned);
  check_bool
    "prunes the oldest by timestamp"
    true
    (List.mem "deploy-20260917T191100Z-1" pruned)
;;

let test_runs_to_prune_excludes_the_new_run () =
  let fresh = "cloud-apply-20260917T205351Z-20714" in
  let older = List.init 20 (fun i -> Printf.sprintf "deploy-20260917T1911%02dZ-1" i) in
  let pruned =
    R.runs_to_prune ~exclude:[ fresh ] ~all_run_ids:(older @ [ fresh ]) ~keep:20 ()
  in
  check_bool "excluded run is never pruned" false (List.mem fresh pruned)
;;

let test_runs_to_prune_keeps_most_recent () =
  let ids = List.init 25 (fun i -> Printf.sprintf "run-%02d" i) in
  let pruned = R.runs_to_prune ~all_run_ids:ids ~keep:20 () in
  check_int "prunes the oldest 5" 5 (List.length pruned);
  check_bool "prunes run-00 (oldest)" true (List.mem "run-00" pruned);
  check_bool "keeps run-24 (newest)" false (List.mem "run-24" pruned)
;;

let test_run_is_live_tracks_the_process_table () =
  if Sys.file_exists "/proc"
  then (
    check_bool "pid 1 is live" true (R.run_is_live "deploy-20260917T191100Z-1");
    check_bool
      "an impossible pid is not live"
      false
      (R.run_is_live "deploy-20260917T191100Z-9999999"))
  else ()
;;

let test_run_is_live_rejects_a_non_pid_tail () =
  check_bool "a non-pid tail is never live" false (R.run_is_live "cloud-apply-notapid");
  check_bool "an id with no tail is never live" false (R.run_is_live "cloud-apply")
;;

let test_runs_to_prune_never_prunes_a_live_run () =
  if Sys.file_exists "/proc"
  then (
    let live = "cloud-destroy-20260919T001717Z-1" in
    let older =
      [ "deploy-20260917T191100Z-9999998"; "cloud-apply-20260918T101500Z-9999999" ]
    in
    let pruned =
      R.runs_to_prune
        ~exclude:(live :: List.filter R.run_is_live (older @ [ live ]))
        ~all_run_ids:(older @ [ live ])
        ~keep:1
        ()
    in
    check_bool "a live run is never pruned" false (List.mem live pruned);
    check_bool
      "older dead runs are still reclaimed as overflow"
      true
      (List.mem "deploy-20260917T191100Z-9999998" pruned))
  else ()
;;

let%test "generate_run_id: format" = test_generate_run_id_format ()
let%test "generate_run_id: ends with pid" = test_generate_run_id_ends_with_pid ()
let%test "generate_run_id: deterministic" = test_generate_run_id_deterministic ()
let%test "tail_lines: shorter than n" = test_tail_lines_shorter_than_n ()
let%test "tail_lines: longer than n" = test_tail_lines_longer_than_n ()
let%test "phase_log_content: no stderr" = test_phase_log_content_no_stderr ()
let%test "phase_log_content: with stderr" = test_phase_log_content_with_stderr ()
let%test "format_phase_line: ok" = test_format_phase_line_ok ()
let%test "format_phase_line: failed" = test_format_phase_line_failed ()

let%test "format_failure_report: names run and log" =
  test_format_failure_report_names_run_and_log ()
;;

let%test "run_is_live: tracks the process table" =
  test_run_is_live_tracks_the_process_table ()
;;

let%test "run_is_live: rejects a non-pid tail" =
  test_run_is_live_rejects_a_non_pid_tail ()
;;

let%test "runs_to_prune: under limit" = test_runs_to_prune_under_limit ()
let%test "runs_to_prune: keeps most recent" = test_runs_to_prune_keeps_most_recent ()

let%test "runs_to_prune: orders by timestamp across prefixes" =
  test_runs_to_prune_orders_by_timestamp_across_prefixes ()
;;

let%test "runs_to_prune: never prunes the excluded run" =
  test_runs_to_prune_excludes_the_new_run ()
;;

let%test "runs_to_prune: never prunes a live run" =
  test_runs_to_prune_never_prunes_a_live_run ()
;;
