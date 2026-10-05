let check_snapshot name ~kinds ~rows ~expected =
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string (Windtrap.float 0.0)))
    ~msg:name
    expected
    (Sol_outbox.For_testing.scoped_snapshot ~kinds rows)
;;

let () =
  Windtrap.run
    "outbox metric snapshot"
    [ Windtrap.test "an empty owned queue reports zero for every declared kind" (fun () ->
        check_snapshot
          "empty"
          ~kinds:[ "order_placed"; "order_fulfilled" ]
          ~rows:[]
          ~expected:[ "order_placed", 0.0; "order_fulfilled", 0.0 ])
    ; Windtrap.test
        "a drained kind returns to zero while others keep their values"
        (fun () ->
           check_snapshot
             "drained"
             ~kinds:[ "order_placed"; "order_fulfilled" ]
             ~rows:[ "order_placed", 4.0 ]
             ~expected:[ "order_placed", 4.0; "order_fulfilled", 0.0 ])
    ; Windtrap.test "rows for kinds this relay does not own are not emitted" (fun () ->
        check_snapshot
          "scoped"
          ~kinds:[ "order_placed" ]
          ~rows:[ "order_placed", 2.0; "other_owner", 9.0 ]
          ~expected:[ "order_placed", 2.0 ])
    ]
;;
