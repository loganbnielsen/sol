(* Tests for Sol_cli_process: successful run, non-zero exit, captured stderr,
   redaction in echo output. *)

let check = Alcotest.(check int)
let check_str = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

(* ── helpers ─────────────────────────────────────────────────────────────── *)

let ok_result = function
  | Ok r -> r
  | Error e -> Alcotest.fail ("unexpected error: " ^ Sol_cli_process.error_to_string e)
;;

let err_result = function
  | Error e -> e
  | Ok _ -> Alcotest.fail "expected error but got Ok"
;;

(* Capture stdout written by [f] into a string. *)
let capture_stdout f =
  let pipe_r, pipe_w = Unix.pipe () in
  let saved = Unix.dup Unix.stdout in
  Unix.dup2 pipe_w Unix.stdout;
  Unix.close pipe_w;
  (try f () with
   | exn ->
     Unix.dup2 saved Unix.stdout;
     Unix.close saved;
     Unix.close pipe_r;
     raise exn);
  Unix.dup2 saved Unix.stdout;
  Unix.close saved;
  let ic = Unix.in_channel_of_descr pipe_r in
  let s = In_channel.input_all ic in
  (try Unix.close pipe_r with
   | _ -> ());
  s
;;

(* ── tests ───────────────────────────────────────────────────────────────── *)

let test_successful_run () =
  let r = ok_result (Sol_cli_process.run (Sol_cli_process.cmd [ "echo"; "hello" ])) in
  check "exit code" 0 r.Sol_cli_process.exit_code;
  check_str "stdout" "hello" r.Sol_cli_process.stdout
;;

let test_non_zero_exit () =
  let r = ok_result (Sol_cli_process.run (Sol_cli_process.cmd [ "false" ])) in
  check_bool "non-zero" true (r.Sol_cli_process.exit_code <> 0)
;;

let test_non_zero_via_run_ok () =
  match Sol_cli_process.run_ok (Sol_cli_process.cmd [ "false" ]) with
  | Error (Sol_cli_process.Non_zero { exit_code; _ }) ->
    check_bool "exit_code non-zero" true (exit_code <> 0)
  | Error e -> Alcotest.fail ("wrong error: " ^ Sol_cli_process.error_to_string e)
  | Ok () -> Alcotest.fail "expected Non_zero error"
;;

let test_captured_stderr () =
  let r =
    ok_result
      (Sol_cli_process.run (Sol_cli_process.cmd [ "sh"; "-c"; "echo oops >&2; exit 1" ]))
  in
  check_str "stderr captured" "oops" r.Sol_cli_process.stderr;
  check "exit code" 1 r.Sol_cli_process.exit_code
;;

let test_stdout_and_stderr_separate () =
  let r =
    ok_result
      (Sol_cli_process.run (Sol_cli_process.cmd [ "sh"; "-c"; "echo out; echo err >&2" ]))
  in
  check_str "stdout" "out" r.Sol_cli_process.stdout;
  check_str "stderr" "err" r.Sol_cli_process.stderr
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
  let output =
    capture_stdout (fun () ->
      ignore
        (Sol_cli_process.run
           ~echo:true
           (Sol_cli_process.cmd ~redact:[ secret ] [ "echo"; secret ])))
  in
  check_bool "secret not in echo" false (Sol_cli_string.contains output ~needle:secret);
  check_bool
    "redaction marker present"
    true
    (Sol_cli_string.contains output ~needle:"***")
;;

let test_no_shell_expansion () =
  let r = ok_result (Sol_cli_process.run (Sol_cli_process.cmd [ "echo"; "$HOME" ])) in
  check_str "no shell expansion" "$HOME" r.Sol_cli_process.stdout
;;

let test_run_shell_success () =
  let r = ok_result (Sol_cli_process.run_shell "echo hello-shell") in
  check_str "shell stdout" "hello-shell" r.Sol_cli_process.stdout;
  check "shell exit" 0 r.Sol_cli_process.exit_code
;;

let test_run_shell_nonzero () =
  let r = ok_result (Sol_cli_process.run_shell "exit 42") in
  check "shell exit 42" 42 r.Sol_cli_process.exit_code
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

(* ── suite ───────────────────────────────────────────────────────────────── *)

(* REFAC-116: Ok means the command succeeded. *)
let test_run_success_and_output () =
  let open Sol_cli_process in
  (match output (cmd [ "sh"; "-c"; "echo hi" ]) with
   | Ok s -> Alcotest.(check string) "stdout (trimmed, as run does)" "hi" s
   | Error e -> Alcotest.fail (error_to_string e));
  (match run_success (cmd [ "sh"; "-c"; "echo out; echo err >&2; exit 3" ]) with
   | Error (Non_zero r) ->
     Alcotest.(check int) "exit code" 3 r.exit_code;
     Alcotest.(check string) "stdout kept" "out" r.stdout;
     Alcotest.(check string) "stderr kept" "err" r.stderr
   | Ok _ -> Alcotest.fail "a failing command was Ok"
   | Error e -> Alcotest.fail (error_to_string e));
  match output (cmd [ "/nonexistent-zxqw" ]) with
  | Error (Spawn_failed _) -> ()
  | _ -> Alcotest.fail "a missing binary is Spawn_failed"
;;

let test_check_is_idempotent () =
  let open Sol_cli_process in
  let r = run (cmd [ "sh"; "-c"; "exit 2" ]) in
  Alcotest.(check bool) "check (check r) = check r" true (check (check r) = check r);
  Alcotest.(check bool) "run itself is Ok for a non-zero exit" true (Result.is_ok r)
;;

let test_failure_output () =
  let f = Sol_cli_process.failure_output in
  Alcotest.(check string) "stderr first" "boom" (f ~stdout:"out" ~stderr:" boom\n");
  Alcotest.(check string)
    "stdout when stderr is empty"
    "out"
    (f ~stdout:"out\n" ~stderr:"  ");
  Alcotest.(check string) "empty" "" (f ~stdout:"" ~stderr:"")
;;

let () =
  Alcotest.run
    "sol_cli_process"
    [ ( "run"
      , [ Alcotest.test_case "successful run" `Quick test_successful_run
        ; Alcotest.test_case "non-zero exit" `Quick test_non_zero_exit
        ; Alcotest.test_case "run_ok non-zero" `Quick test_non_zero_via_run_ok
        ; Alcotest.test_case
            "run_success and output (REFAC-116)"
            `Quick
            test_run_success_and_output
        ; Alcotest.test_case "check is idempotent" `Quick test_check_is_idempotent
        ; Alcotest.test_case "failure_output" `Quick test_failure_output
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
