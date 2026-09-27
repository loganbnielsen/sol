(* REFAC-137: one rule for a primitive's settings -- trimmed, and blank reads as
   unset. [Unix.putenv] cannot unset a variable, which is itself why "" has to
   mean unset. *)

let with_env name value f =
  let saved = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () -> Unix.putenv name (Option.value saved ~default:"")) f
;;

let check name value expected =
  with_env name value (fun () ->
    Alcotest.(check (option string))
      (Printf.sprintf "%s=%S" name value)
      expected
      (Sol_runtime.setting name))
;;

let () =
  Alcotest.run
    "sol_runtime setting"
    [ ( "setting"
      , [ Alcotest.test_case "a value is trimmed" `Quick (fun () ->
            check "SOL_TEST_SETTING" "  8080 \n" (Some "8080"))
        ; Alcotest.test_case "blank is unset" `Quick (fun () ->
            check "SOL_TEST_SETTING" "   " None)
        ; Alcotest.test_case "empty is unset" `Quick (fun () ->
            check "SOL_TEST_SETTING" "" None)
        ; Alcotest.test_case "never set is unset" `Quick (fun () ->
            Alcotest.(check (option string))
              "absent"
              None
              (Sol_runtime.setting "SOL_TEST_SETTING_NEVER_SET"))
        ] )
    ]
;;
