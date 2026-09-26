let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)

module R = Sol_cli_run_log

(* ── generate_run_id ─────────────────────────────────────────────────── *)

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

(* ── tail_lines ──────────────────────────────────────────────────────── *)

let test_tail_lines_shorter_than_n () =
  check_string "returns input unchanged" "a\nb" (R.tail_lines ~n:10 "a\nb")
;;

let test_tail_lines_longer_than_n () =
  let s = String.concat "\n" (List.init 100 string_of_int) in
  let tailed = R.tail_lines ~n:3 s in
  check_string "last 3 lines" "97\n98\n99" tailed
;;

(* ── phase_log_content ───────────────────────────────────────────────── *)

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

(* ── format_phase_line ───────────────────────────────────────────────── *)

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

(* ── format_failure_report ───────────────────────────────────────────── *)

let contains needle haystack = Sol_cli_string.contains ~needle haystack

(* FEAT-055: a failing phase must name the run, not just the log path, so a
   deploy is recoverable after the terminal that ran it is gone. *)
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

(* ── runs_to_prune ───────────────────────────────────────────────────── *)

let test_runs_to_prune_under_limit () =
  check_int
    "nothing to prune"
    0
    (List.length (R.runs_to_prune ~all_run_ids:[ "a-1"; "a-2" ] ~keep:20 ()))
;;

(* HARDEN-002 regression: pruning ordered whole run ids lexicographically, so a
   fresh run whose command prefix sorted early ("cloud-apply-…" < "deploy-…") was
   pruned as if it were the oldest -- deleting the directory create had just
   made, and leaving the phase-log write to fail with an uncaught Sys_error. *)
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

(* A run must never be a pruning candidate for itself, whatever the ordering. *)
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

(* ── run_is_live ─────────────────────────────────────────────────────── *)

(* [run_is_live] is what stops a live command's run directory being pruned. It
   reads the process table, so on a platform without /proc it is conservatively
   [false] and pruning keeps its previous behaviour; the assertions that need
   /proc are skipped there rather than asserted about a different platform. *)
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

(* INFRA-033, the regression: a long-running command (a cloud destroy takes tens
   of minutes) writes into its run directory at the end of every phase. Pruning
   that directory made the next write raise an uncaught [Sys_error], aborting the
   teardown with the target still provisioned and billing — which is how Run 5
   attempt 2's first destroy died. [create] now passes every live run in
   [exclude], and this pins that a live run survives while dead overflow is still
   reclaimed. *)
let test_runs_to_prune_never_prunes_a_live_run () =
  if Sys.file_exists "/proc"
  then (
    let live = "cloud-destroy-20260919T001717Z-1" in
    (* Impossibly high pids for the "dead" runs: low pids are taken by kernel
       threads, and using one would make that run live and quietly test nothing. *)
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

let () =
  Alcotest.run
    "run_log"
    [ ( "generate_run_id"
      , [ Alcotest.test_case "format" `Quick test_generate_run_id_format
        ; Alcotest.test_case "ends with pid" `Quick test_generate_run_id_ends_with_pid
        ; Alcotest.test_case "deterministic" `Quick test_generate_run_id_deterministic
        ] )
    ; ( "tail_lines"
      , [ Alcotest.test_case "shorter than n" `Quick test_tail_lines_shorter_than_n
        ; Alcotest.test_case "longer than n" `Quick test_tail_lines_longer_than_n
        ] )
    ; ( "phase_log_content"
      , [ Alcotest.test_case "no stderr" `Quick test_phase_log_content_no_stderr
        ; Alcotest.test_case "with stderr" `Quick test_phase_log_content_with_stderr
        ] )
    ; ( "format_phase_line"
      , [ Alcotest.test_case "ok" `Quick test_format_phase_line_ok
        ; Alcotest.test_case "failed" `Quick test_format_phase_line_failed
        ] )
    ; ( "format_failure_report"
      , [ Alcotest.test_case
            "names run and log"
            `Quick
            test_format_failure_report_names_run_and_log
        ] )
    ; ( "run_is_live"
      , [ Alcotest.test_case
            "tracks the process table"
            `Quick
            test_run_is_live_tracks_the_process_table
        ; Alcotest.test_case
            "rejects a non-pid tail"
            `Quick
            test_run_is_live_rejects_a_non_pid_tail
        ] )
    ; ( "runs_to_prune"
      , [ Alcotest.test_case "under limit" `Quick test_runs_to_prune_under_limit
        ; Alcotest.test_case
            "keeps most recent"
            `Quick
            test_runs_to_prune_keeps_most_recent
        ; Alcotest.test_case
            "orders by timestamp across prefixes"
            `Quick
            test_runs_to_prune_orders_by_timestamp_across_prefixes
        ; Alcotest.test_case
            "never prunes the excluded run"
            `Quick
            test_runs_to_prune_excludes_the_new_run
        ; Alcotest.test_case
            "never prunes a live run"
            `Quick
            test_runs_to_prune_never_prunes_a_live_run
        ] )
    ]
;;
