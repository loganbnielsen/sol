let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let contains needle haystack = Sol_cli_string.contains ~needle haystack
let refresh ~exit_code = Sol_cli_process.completed ~exit_code ~stdout:"" ~stderr:""

let test_the_exit_code_decides_the_drift_verdict () =
  check_bool
    "a refresh-only plan with no changes is in sync"
    true
    (Sol_cli_environment_stage.drift_of_refresh (refresh ~exit_code:0)
     = Sol_cli_environment_stage.In_sync);
  check_bool
    "-detailed-exitcode 2 is drift, not in sync"
    true
    (Sol_cli_environment_stage.drift_of_refresh (refresh ~exit_code:2)
     = Sol_cli_environment_stage.Detected);
  (match Sol_cli_environment_stage.drift_of_refresh (refresh ~exit_code:1) with
   | Sol_cli_environment_stage.Unknown reason ->
     check_bool "a failing refresh says why" true (contains "exited with code 1" reason)
   | Sol_cli_environment_stage.In_sync ->
     Windtrap.fail "a failing refresh was reported as no drift"
   | Sol_cli_environment_stage.Detected ->
     Windtrap.fail "a failing refresh was reported as drift");
  match
    Sol_cli_environment_stage.drift_of_refresh
      (Error (Sol_cli_process.Spawn_failed "terraform: No such file or directory"))
  with
  | Sol_cli_environment_stage.Unknown reason ->
    check_bool
      "a spawn failure is Unknown, never no drift"
      true
      (contains "No such file" reason)
  | Sol_cli_environment_stage.In_sync ->
    Windtrap.fail "an unrunnable refresh was reported as no drift"
  | Sol_cli_environment_stage.Detected ->
    Windtrap.fail "an unrunnable refresh was reported as drift"
;;

let test_rendering_keeps_the_three_verdicts_distinct () =
  let render = Sol_cli_environment_stage.drift_to_string in
  let in_sync = render Sol_cli_environment_stage.In_sync in
  check_bool "no drift reads as None" true (contains "None" in_sync);
  check_bool "no drift never reads as Unknown" false (contains "Unknown" in_sync);
  let detected = render Sol_cli_environment_stage.Detected in
  check_bool "drift reads as Detected" true (contains "Detected" detected);
  check_bool "drift never reads as None" false (contains "None" detected);
  let unknown =
    render (Sol_cli_environment_stage.Unknown "the state backend could not be read")
  in
  check_bool "an unreadable drift reads as Unknown" true (contains "Unknown" unknown);
  check_bool
    "and carries the reason"
    true
    (contains "the state backend could not be read" unknown);
  check_bool "and is never None" false (contains "None" unknown)
;;

let%test "drift: the exit code decides the verdict" =
  test_the_exit_code_decides_the_drift_verdict ()
;;

let%test "drift: the three verdicts stay distinct" =
  test_rendering_keeps_the_three_verdicts_distinct ()
;;
