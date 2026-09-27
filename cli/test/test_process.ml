let check = Alcotest.(check int)
let check_str = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

let ok_result = function
  | Ok r -> r
  | Error e -> Alcotest.fail ("unexpected error: " ^ Sol_cli_process.error_to_string e)
;;

let err_result = function
  | Error e -> e
  | Ok _ -> Alcotest.fail "expected error but got Ok"
;;

let test_successful_run () =
  let r = ok_result (Sol_cli_process.run (Sol_cli_process.cmd [ "echo"; "hello" ])) in
  check_str "stdout" "hello" r.stdout
;;

let test_non_zero_exit () =
  match err_result (Sol_cli_process.run (Sol_cli_process.cmd [ "false" ])) with
  | Sol_cli_process.Non_zero { exit_code; _ } ->
    check_bool "exit_code non-zero" true (exit_code <> 0)
  | e -> Alcotest.fail ("wrong error: " ^ Sol_cli_process.error_to_string e)
;;

let test_captured_stderr () =
  match
    err_result
      (Sol_cli_process.run
         (Sol_cli_process.cmd [ "sh"; "-c"; "echo out; echo oops >&2; exit 3" ]))
  with
  | Sol_cli_process.Non_zero { exit_code; stdout; stderr } ->
    check "exit code" 3 exit_code;
    check_str "stdout kept" "out" stdout;
    check_str "stderr captured" "oops" stderr
  | e -> Alcotest.fail ("wrong error: " ^ Sol_cli_process.error_to_string e)
;;

let test_stdout_and_stderr_separate () =
  let r =
    ok_result
      (Sol_cli_process.run (Sol_cli_process.cmd [ "sh"; "-c"; "echo out; echo err >&2" ]))
  in
  check_str "stdout" "out" r.stdout;
  check_str "stderr" "err" r.stderr
;;

let test_spawn_failed () =
  match
    err_result (Sol_cli_process.run (Sol_cli_process.cmd [ "/nonexistent-binary-xyz" ]))
  with
  | Sol_cli_process.Spawn_failed _ -> ()
  | e -> Alcotest.fail ("expected Spawn_failed, got: " ^ Sol_cli_process.error_to_string e)
;;

let test_chdir_failed () =
  match
    err_result
      (Sol_cli_process.run (Sol_cli_process.cmd ~cwd:"/nonexistent-dir-xyz" [ "pwd" ]))
  with
  | Sol_cli_process.Spawn_failed msg ->
    check_bool "mentions chdir" true (Sol_cli_string.contains msg ~needle:"chdir")
  | e -> Alcotest.fail ("expected Spawn_failed, got: " ^ Sol_cli_process.error_to_string e)
;;

let test_redaction_in_echo () =
  let secret = "s3cr3t-p4ss" in
  let (), reported =
    Sol_cli_report.collect (fun () ->
      ignore
        (Sol_cli_process.run
           ~echo:true
           (Sol_cli_process.cmd ~redact:[ secret ] [ "echo"; secret ])))
  in
  let output = reported |> List.map snd |> String.concat "\n" in
  check_bool "secret not in echo" false (Sol_cli_string.contains output ~needle:secret);
  check_bool
    "redaction marker present"
    true
    (Sol_cli_string.contains output ~needle:"***")
;;

let test_no_shell_expansion () =
  let r = ok_result (Sol_cli_process.run (Sol_cli_process.cmd [ "echo"; "$HOME" ])) in
  check_str "no shell expansion" "$HOME" r.stdout
;;

let test_run_shell_success () =
  let r = ok_result (Sol_cli_process.run_shell "echo hello-shell") in
  check_str "shell stdout" "hello-shell" r.stdout
;;

let test_run_shell_nonzero () =
  match err_result (Sol_cli_process.run_shell "exit 42") with
  | Sol_cli_process.Non_zero { exit_code; _ } -> check "shell exit 42" 42 exit_code
  | e -> Alcotest.fail ("wrong error: " ^ Sol_cli_process.error_to_string e)
;;

let test_error_to_string_spawn () =
  let s = Sol_cli_process.error_to_string (Sol_cli_process.Spawn_failed "oops") in
  check_bool
    "Sol_cli_string.contains spawn"
    true
    (Sol_cli_string.contains s ~needle:"spawn")
;;

let test_error_to_string_nonzero () =
  let s =
    Sol_cli_process.error_to_string
      (Sol_cli_process.Non_zero { exit_code = 5; stdout = ""; stderr = "bad" })
  in
  check_bool "Sol_cli_string.contains 5" true (Sol_cli_string.contains s ~needle:"5")
;;

let test_error_to_string_keeps_stdout () =
  let s =
    Sol_cli_process.error_to_string
      (Sol_cli_process.Non_zero { exit_code = 1; stdout = "said on stdout"; stderr = "" })
  in
  check_bool "stdout kept" true (Sol_cli_string.contains s ~needle:"said on stdout")
;;

let test_run_is_success () =
  let open Sol_cli_process in
  (match run (cmd [ "sh"; "-c"; "echo hi" ]) with
   | Ok { stdout; _ } -> Alcotest.(check string) "stdout (trimmed)" "hi" stdout
   | Error e -> Alcotest.fail (error_to_string e));
  match run (cmd [ "/nonexistent-zxqw" ]) with
  | Error (Spawn_failed _) -> ()
  | _ -> Alcotest.fail "a missing binary is Spawn_failed"
;;

let test_completed () =
  let open Sol_cli_process in
  (match completed ~exit_code:0 ~stdout:"o" ~stderr:"e" with
   | Ok { stdout = "o"; stderr = "e" } -> ()
   | _ -> Alcotest.fail "exit 0 is Ok with both streams");
  match completed ~exit_code:2 ~stdout:"o" ~stderr:"e" with
  | Error (Non_zero { exit_code = 2; stdout = "o"; stderr = "e" }) -> ()
  | _ -> Alcotest.fail "exit 2 is Non_zero with the code and both streams"
;;

let test_failure_message () =
  let f stdout stderr =
    Sol_cli_process.failure_message { exit_code = 4; stdout; stderr }
  in
  Alcotest.(check string) "stderr first" "boom" (f "out" " boom\n");
  Alcotest.(check string) "stdout when stderr is blank" "out" (f "out\n" "  ");
  Alcotest.(check string) "the code when both are blank" "exited with code 4" (f "" " ")
;;

let () =
  Alcotest.run
    "sol_cli_process"
    [ ( "run"
      , [ Alcotest.test_case "successful run" `Quick test_successful_run
        ; Alcotest.test_case "non-zero exit" `Quick test_non_zero_exit
        ; Alcotest.test_case
            "run is Ok only on success (REFAC-124)"
            `Quick
            test_run_is_success
        ; Alcotest.test_case "completed shares run's contract" `Quick test_completed
        ; Alcotest.test_case "failure_message" `Quick test_failure_message
        ; Alcotest.test_case
            "error_to_string keeps stdout"
            `Quick
            test_error_to_string_keeps_stdout
        ; Alcotest.test_case "captured stderr" `Quick test_captured_stderr
        ; Alcotest.test_case
            "stdout stderr separate"
            `Quick
            test_stdout_and_stderr_separate
        ; Alcotest.test_case "spawn failed" `Quick test_spawn_failed
        ; Alcotest.test_case "chdir failed" `Quick test_chdir_failed
        ; Alcotest.test_case "no shell expansion" `Quick test_no_shell_expansion
        ] )
    ; ( "echo_redaction"
      , [ Alcotest.test_case "secret redacted in echo" `Quick test_redaction_in_echo ] )
    ; ( "run_shell"
      , [ Alcotest.test_case "shell success" `Quick test_run_shell_success
        ; Alcotest.test_case "shell non-zero" `Quick test_run_shell_nonzero
        ] )
    ; ( "error_to_string"
      , [ Alcotest.test_case "spawn error" `Quick test_error_to_string_spawn
        ; Alcotest.test_case "non-zero error" `Quick test_error_to_string_nonzero
        ] )
    ]
;;
