let expect_refused name kinds =
  match Sol_outbox.For_testing.validate_kinds kinds with
  | Some (`Config _) -> ()
  | Some (`Database _) -> Windtrap.failf "%s: expected a configuration refusal" name
  | None -> Windtrap.failf "%s: expected a refusal" name
;;

let expect_accepted name kinds =
  match Sol_outbox.For_testing.validate_kinds kinds with
  | None -> ()
  | Some (`Config message) -> Windtrap.failf "%s: unexpected refusal: %s" name message
  | Some (`Database message) ->
    Windtrap.failf "%s: unexpected database error: %s" name message
;;

let () =
  Windtrap.run
    "outbox kind validation"
    [ Windtrap.test "the current uppercase kinds are selectable" (fun () ->
        Windtrap.is_true
          ~msg:"OrderPlaced"
          (Sol_outbox.For_testing.kind_is_selectable "OrderPlaced");
        Windtrap.is_true
          ~msg:"OrderFulfilled"
          (Sol_outbox.For_testing.kind_is_selectable "OrderFulfilled"))
    ; Windtrap.test "a comma or an empty name is not selectable" (fun () ->
        Windtrap.is_false ~msg:"comma" (Sol_outbox.For_testing.kind_is_selectable "a,b");
        Windtrap.is_false ~msg:"empty" (Sol_outbox.For_testing.kind_is_selectable ""))
    ; Windtrap.test "an empty declaration refuses relay startup" (fun () ->
        expect_refused "empty" [])
    ; Windtrap.test "a comma-containing declaration refuses" (fun () ->
        expect_refused "comma" [ "a,b" ])
    ; Windtrap.test "an empty kind name refuses" (fun () -> expect_refused "blank" [ "" ])
    ; Windtrap.test "a duplicate declaration refuses" (fun () ->
        expect_refused "duplicate" [ "OrderPlaced"; "OrderPlaced" ])
    ; Windtrap.test "distinct valid kinds are accepted" (fun () ->
        expect_accepted "valid" [ "OrderPlaced"; "OrderFulfilled" ])
    ]
;;
