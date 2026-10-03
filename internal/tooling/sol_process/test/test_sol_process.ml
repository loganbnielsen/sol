let check_int msg expected actual = Windtrap.equal Windtrap.int ~msg expected actual
let check_str msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let status_testable =
  Windtrap.testable
    ~pp:(fun fmt -> function
       | Sol_process.Exited n -> Format.fprintf fmt "Exited %d" n
       | Signaled n -> Format.fprintf fmt "Signaled %d" n
       | Stopped n -> Format.fprintf fmt "Stopped %d" n)
    ()
;;

let check_status msg expected actual = Windtrap.equal status_testable ~msg expected actual

let test_run_success () =
  let r = Sol_process.run_shell ~echo:false "echo hello" in
  check_status "status" (Sol_process.Exited 0) r.status;
  check_int "exit code 0" 0 (Sol_process.exit_code r);
  check_str "stdout" "hello" r.stdout
;;

let test_run_nonzero () =
  let r = Sol_process.run_shell ~echo:false "exit 42" in
  check_status "status" (Sol_process.Exited 42) r.status;
  check_int "exit code 42" 42 (Sol_process.exit_code r)
;;

let test_status_shell_codes () =
  check_int "exited" 42 (Sol_process.status_to_exit_code (Sol_process.Exited 42));
  check_int "signaled" 143 (Sol_process.status_to_exit_code (Sol_process.Signaled 15));
  check_int "stopped" 147 (Sol_process.status_to_exit_code (Sol_process.Stopped 19))
;;

let test_run_signaled () =
  let r = Sol_process.run_argv ~echo:false [ "sh"; "-c"; "kill -TERM $$" ] in
  match r.status with
  | Sol_process.Signaled n ->
    check_int "exit code is 128+signal" (128 + n) (Sol_process.exit_code r)
  | status -> check_status "status" (Sol_process.Signaled 15) status
;;

let test_run_stderr_captured () =
  let r = Sol_process.run_shell ~echo:false "echo bar >&2" in
  check_str "stdout empty" "" r.stdout;
  check_str "stderr" "bar" r.stderr
;;

let test_run_both_streams () =
  let r = Sol_process.run_shell ~echo:false "echo out; echo err >&2" in
  check_str "stdout" "out" r.stdout;
  check_str "stderr" "err" r.stderr
;;

let test_run_command_not_found () =
  let r =
    Sol_process.run_shell ~echo:false "nonexistent_command_sol_process_test_abc123"
  in
  check_bool "exit code non-zero" true (Sol_process.exit_code r <> 0)
;;

let test_run_argv_basic () =
  let r = Sol_process.run_argv ~echo:false [ "echo"; "hello world" ] in
  check_status "status" (Sol_process.Exited 0) r.status;
  check_int "exit code 0" 0 (Sol_process.exit_code r);
  check_str "stdout" "hello world" r.stdout
;;

let test_run_argv_special_chars () =
  let r = Sol_process.run_argv ~echo:false [ "printf"; "%s"; "a b" ] in
  check_str "stdout with space" "a b" r.stdout
;;

let test_run_argv_no_shell_interpretation () =
  let r = Sol_process.run_argv ~echo:false [ "printf"; "%s"; "a; echo injected" ] in
  check_int "exit code 0" 0 (Sol_process.exit_code r);
  check_str "metacharacters are literal" "a; echo injected" r.stdout
;;

let test_run_argv_command_not_found () =
  let r =
    Sol_process.run_argv ~echo:false [ "nonexistent_command_sol_process_test_abc123" ]
  in
  check_status "status" (Sol_process.Exited 127) r.status;
  check_bool "exit code non-zero" true (Sol_process.exit_code r <> 0);
  check_str "stdout empty" "" r.stdout
;;

let lines_or_fail cmd =
  match Sol_process.lines_shell_checked ~echo:false cmd with
  | Ok lines -> lines
  | Error r -> Windtrap.fail (Sol_process.failure_message r)
;;

let test_lines_basic () =
  let ls = lines_or_fail "printf 'a\\nb\\nc'" in
  check_bool "three lines" true (List.length ls = 3);
  check_str "first line" "a" (List.nth ls 0);
  check_str "last line" "c" (List.nth ls 2)
;;

let test_lines_empty_filtered () =
  let ls = lines_or_fail "printf 'a\\n\\nb'" in
  check_bool "blank line filtered" true (List.length ls = 2)
;;

let test_lines_stderr_not_captured () =
  let ls = lines_or_fail "echo out; echo err >&2" in
  check_bool "only one line" true (List.length ls = 1);
  check_str "line is from stdout" "out" (List.nth ls 0)
;;

let test_output_trimmed () =
  let s =
    match Sol_process.output_shell_checked ~echo:false "printf '  hello  '" with
    | Ok s -> s
    | Error r -> Windtrap.fail (Sol_process.failure_message r)
  in
  check_str "trimmed" "hello" s
;;

let test_lines_checked_reports_failure () =
  match Sol_process.lines_shell_checked ~echo:false "echo out; echo err >&2; exit 3" with
  | Ok _ -> Windtrap.fail "a failing command must not read as an empty line list"
  | Error r ->
    check_int "exit code" 3 (Sol_process.exit_code r);
    check_str "stdout is still reported" "out" r.stdout;
    check_str
      "the failure names the cause"
      "exited with code 3: err"
      (Sol_process.failure_message r)
;;

let test_output_checked_reports_failure () =
  match Sol_process.output_shell_checked ~echo:false "printf partial; exit 4" with
  | Ok _ -> Windtrap.fail "a failing command must not read as an empty string"
  | Error r ->
    check_int "exit code" 4 (Sol_process.exit_code r);
    check_str
      "the failure names the cause"
      "exited with code 4"
      (Sol_process.failure_message r)
;;

let test_stream_returns_status_without_capture () =
  let r = Sol_process.run_argv ~echo:false ~stream:true [ "sh"; "-c"; "exit 7" ] in
  check_int "exit code" 7 (Sol_process.exit_code r);
  check_str "nothing is captured when streaming" "" r.stdout
;;

let test_run_rc_success () =
  check_int "rc 0" 0 (Sol_process.run_shell_rc ~echo:false "true")
;;

let test_run_rc_failure () =
  check_bool "rc non-zero" true (Sol_process.run_shell_rc ~echo:false "false" <> 0)
;;

let test_run_ok_success () = Sol_process.run_shell_ok ~echo:false "true"

let test_run_ok_failure () =
  let raised =
    try
      Sol_process.run_shell_ok ~echo:false "false";
      false
    with
    | Failure _ -> true
  in
  check_bool "raises Failure on non-zero" true raised
;;

let with_alarm seconds f =
  let previous = Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> raise Exit)) in
  ignore (Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.; it_value = seconds });
  let outcome =
    match f () with
    | value -> Ok value
    | exception Exit -> Error `Timed_out
  in
  ignore (Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.; it_value = 0. });
  Sys.set_signal Sys.sigalrm previous;
  outcome
;;

let fd_count () = Array.length (Sys.readdir "/proc/self/fd")

let check_drained label runner =
  match with_alarm 5.0 runner with
  | Error `Timed_out -> Windtrap.fail (label ^ " stalled on a full stderr pipe")
  | Ok r ->
    check_str (label ^ " stdout intact") "done" r.Sol_process.stdout;
    check_int (label ^ " stderr drained") 262144 (String.length r.Sol_process.stderr)
;;

let test_shell_drains_both_streams () =
  check_drained "run_shell" (fun () ->
    Sol_process.run_shell ~echo:false "head -c 262144 /dev/zero >&2; echo done")
;;

let test_argv_drains_both_streams () =
  check_drained "run_argv" (fun () ->
    Sol_process.run_argv
      ~echo:false
      [ "sh"; "-c"; "head -c 262144 /dev/zero >&2; echo done" ])
;;

let test_handled_signal_completes_capture () =
  let previous = Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> ())) in
  let before = fd_count () in
  ignore (Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.; it_value = 0.05 });
  let r = Sol_process.run_argv ~echo:false [ "sh"; "-c"; "sleep 0.2; echo done" ] in
  ignore (Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.; it_value = 0. });
  Sys.set_signal Sys.sigalrm previous;
  check_str "completed despite a handled signal" "done" r.Sol_process.stdout;
  check_int "no descriptor leak" before (fd_count ())
;;

let test_interrupted_capture_cleans_up () =
  let previous = Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> raise Exit)) in
  let before = fd_count () in
  ignore (Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.; it_value = 0.05 });
  let raised =
    match Sol_process.run_argv ~echo:false [ "sleep"; "5" ] with
    | _ -> false
    | exception Exit -> true
  in
  ignore (Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.; it_value = 0. });
  Sys.set_signal Sys.sigalrm previous;
  check_bool "interruption propagates" true raised;
  check_int "no descriptor leak on interruption" before (fd_count ());
  let unreaped =
    match Unix.waitpid [ Unix.WNOHANG ] (-1) with
    | 0, _ -> 0
    | pid, _ -> pid
    | exception Unix.Unix_error _ -> 0
  in
  check_int "no unreaped child" 0 unreaped
;;

let () =
  Windtrap.run
    "sol_process"
    [ Windtrap.group
        "run"
        [ Windtrap.test "success result" test_run_success
        ; Windtrap.test "non-zero exit code" test_run_nonzero
        ; Windtrap.test "shell-compatible status codes" test_status_shell_codes
        ; Windtrap.test "signaled status" test_run_signaled
        ; Windtrap.test "stderr captured" test_run_stderr_captured
        ; Windtrap.test "both streams" test_run_both_streams
        ; Windtrap.test "command not found" test_run_command_not_found
        ]
    ; Windtrap.group
        "run_argv"
        [ Windtrap.test "basic argv" test_run_argv_basic
        ; Windtrap.test "special chars quoted" test_run_argv_special_chars
        ; Windtrap.test "no shell interpretation" test_run_argv_no_shell_interpretation
        ; Windtrap.test "command not found" test_run_argv_command_not_found
        ]
    ; Windtrap.group
        "lines"
        [ Windtrap.test "basic lines" test_lines_basic
        ; Windtrap.test "blank lines filtered" test_lines_empty_filtered
        ; Windtrap.test "stderr excluded" test_lines_stderr_not_captured
        ; Windtrap.test
            "a failed read is an error, not []"
            test_lines_checked_reports_failure
        ]
    ; Windtrap.group
        "output"
        [ Windtrap.test "trimmed string" test_output_trimmed
        ; Windtrap.test
            "a failed read is an error, not \"\""
            test_output_checked_reports_failure
        ]
    ; Windtrap.group
        "stream"
        [ Windtrap.test
            "status without capture"
            test_stream_returns_status_without_capture
        ]
    ; Windtrap.group
        "run_rc"
        [ Windtrap.test "success → 0" test_run_rc_success
        ; Windtrap.test "failure → non-zero" test_run_rc_failure
        ]
    ; Windtrap.group
        "run_ok"
        [ Windtrap.test "success → no raise" test_run_ok_success
        ; Windtrap.test "failure → Failure" test_run_ok_failure
        ]
    ; Windtrap.group
        "streams"
        [ Windtrap.test
            "shell drains both streams (CODE_LAYER-023)"
            test_shell_drains_both_streams
        ; Windtrap.test
            "argv drains both streams (CODE_LAYER-023)"
            test_argv_drains_both_streams
        ]
    ; Windtrap.group
        "ownership"
        [ Windtrap.test
            "handled signal completes capture (CODE_LAYER-025)"
            test_handled_signal_completes_capture
        ; Windtrap.test
            "interrupted capture cleans up (CODE_LAYER-025)"
            test_interrupted_capture_cleans_up
        ]
    ]
;;
