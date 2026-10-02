let with_env name value f =
  let saved = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () -> Unix.putenv name (Option.value saved ~default:"")) f
;;

let check name value expected =
  with_env name value (fun () ->
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:(Printf.sprintf "%s=%S" name value)
      expected
      (Sol_runtime.setting name))
;;

let () =
  Windtrap.run
    "sol_runtime setting"
    [ Windtrap.group
        "setting"
        [ Windtrap.test "a value is trimmed" (fun () ->
            check "SOL_TEST_SETTING" "  8080 \n" (Some "8080"))
        ; Windtrap.test "blank is unset" (fun () -> check "SOL_TEST_SETTING" "   " None)
        ; Windtrap.test "empty is unset" (fun () -> check "SOL_TEST_SETTING" "" None)
        ; Windtrap.test "never set is unset" (fun () ->
            Windtrap.equal
              (Windtrap.option Windtrap.string)
              ~msg:"absent"
              None
              (Sol_runtime.setting "SOL_TEST_SETTING_NEVER_SET"))
        ]
    ]
;;
