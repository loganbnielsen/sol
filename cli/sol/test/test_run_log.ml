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

let contains needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with
  | Not_found -> false
;;

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
    (List.length (R.runs_to_prune ~all_run_ids:[ "a-1"; "a-2" ] ~keep:20))
;;

let test_runs_to_prune_keeps_most_recent () =
  let ids = List.init 25 (fun i -> Printf.sprintf "run-%02d" i) in
  let pruned = R.runs_to_prune ~all_run_ids:ids ~keep:20 in
  check_int "prunes the oldest 5" 5 (List.length pruned);
  check_bool "prunes run-00 (oldest)" true (List.mem "run-00" pruned);
  check_bool "keeps run-24 (newest)" false (List.mem "run-24" pruned)
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
    ; ( "runs_to_prune"
      , [ Alcotest.test_case "under limit" `Quick test_runs_to_prune_under_limit
        ; Alcotest.test_case
            "keeps most recent"
            `Quick
            test_runs_to_prune_keeps_most_recent
        ] )
    ]
;;
