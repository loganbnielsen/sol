(* FEAT-072: the deploy-attempt unit's pure projection. *)

let test_outcome_of () =
  Alcotest.(check bool)
    "Ok is Applied"
    true
    (Sol_cli_deployment_attempt.outcome_of (Ok 1) = Sol_cli_deployment.Applied);
  Alcotest.(check bool)
    "Error is Apply_failed"
    true
    (Sol_cli_deployment_attempt.outcome_of (Error "boom")
     = Sol_cli_deployment.Apply_failed)
;;

let test_start_mints_an_id () =
  let attempt = Sol_cli_deployment_attempt.start () in
  let id = Sol_cli_deployment_attempt.deployment_id attempt in
  Alcotest.(check bool)
    "id is non-empty"
    true
    (String.length (Sol_cli_deployment_id.to_string id) > 0)
;;

let () =
  Alcotest.run
    "deployment_attempt"
    [ ( "attempt"
      , [ Alcotest.test_case "outcome_of" `Quick test_outcome_of
        ; Alcotest.test_case "start mints an id" `Quick test_start_mints_an_id
        ] )
    ]
;;
