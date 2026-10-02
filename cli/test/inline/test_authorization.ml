module A = Sol_cli_authorization

let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let check_grants msg expected actual =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg
    (List.map A.grant_to_string (A.normalize expected))
    (List.map A.grant_to_string (A.normalize actual))
;;

let grant unit capability resource = { A.unit; capability; resource }
let stripe = grant "payments-api" "secret" "stripe"
let legacy = grant "old-api" "secret" "legacy"

let test_absent_grant_is_an_addition () =
  let plan = A.compute ~desired:[ stripe ] ~current:[] ~deployed:(A.Deployed []) in
  check_grants "added" [ stripe ] plan.additions;
  check_grants "kept" [ stripe ] plan.keep;
  check_grants "nothing removed" [] plan.removals
;;

let test_unchanged_grant_is_stable () =
  let plan =
    A.compute ~desired:[ stripe ] ~current:[ stripe ] ~deployed:(A.Deployed [])
  in
  check_grants "nothing added" [] plan.additions;
  check_grants "nothing removed" [] plan.removals;
  check_grants "kept" [ stripe ] plan.keep
;;

let test_undeployed_stale_grant_is_removed () =
  let plan =
    A.compute ~desired:[ stripe ] ~current:[ stripe; legacy ] ~deployed:(A.Deployed [])
  in
  check_grants "removed" [ legacy ] plan.removals;
  check_grants "nothing held" [] plan.held;
  check_grants "kept" [ stripe ] plan.keep
;;

let test_stale_grant_still_deployed_is_held () =
  let plan =
    A.compute
      ~desired:[ stripe ]
      ~current:[ stripe; legacy ]
      ~deployed:(A.Deployed [ legacy ])
  in
  check_grants "nothing removed" [] plan.removals;
  check_grants "held" [ legacy ] plan.held;
  check_grants "kept" [ stripe; legacy ] plan.keep
;;

let test_unobservable_deployed_state_holds_every_stale_grant () =
  let plan =
    A.compute
      ~desired:[ stripe ]
      ~current:[ stripe; legacy ]
      ~deployed:(A.Unobservable "cluster unreachable")
  in
  check_grants "nothing removed" [] plan.removals;
  check_grants "held" [ legacy ] plan.held;
  check_grants "kept" [ stripe; legacy ] plan.keep;
  check_bool "a note is emitted" true (plan.notes <> []);
  check_bool
    "the reason is named"
    true
    (Sol_cli_string.contains ~needle:"cluster unreachable" plan.held_reason)
;;

let test_additions_are_not_held_back_by_a_removal () =
  let plan =
    A.compute ~desired:[ stripe ] ~current:[ legacy ] ~deployed:(A.Deployed [ legacy ])
  in
  check_grants "added" [ stripe ] plan.additions;
  check_grants "nothing removed" [] plan.removals;
  check_grants "held" [ legacy ] plan.held
;;

let test_plan_renders_readably () =
  let plan =
    A.compute ~desired:[ stripe ] ~current:[ legacy ] ~deployed:(A.Deployed [])
  in
  let lines = A.render plan in
  check_bool "addition line" true (List.mem ("+ " ^ A.grant_to_string stripe) lines);
  check_bool "removal line" true (List.mem ("- " ^ A.grant_to_string legacy) lines)
;;

let test_plan_is_target_wide () =
  let checkout = grant "checkout-api" "secret" "stripe" in
  let plan =
    A.compute ~desired:[ stripe; checkout ] ~current:[] ~deployed:(A.Deployed [])
  in
  check_grants "every domain is covered" [ stripe; checkout ] plan.additions
;;

let%test "authorization: an absent grant is an addition" =
  test_absent_grant_is_an_addition ()
;;

let%test "authorization: an unchanged grant is neither added nor removed" =
  test_unchanged_grant_is_stable ()
;;

let%test "authorization: an undeployed stale grant is removed" =
  test_undeployed_stale_grant_is_removed ()
;;

let%test
    "authorization: a stale grant still used by a deployed workload is held, not revoked"
  =
  test_stale_grant_still_deployed_is_held ()
;;

let%test
    "authorization: an unobservable deployed state holds every stale grant and says so"
  =
  test_unobservable_deployed_state_holds_every_stale_grant ()
;;

let%test "authorization: additions are not held back by a pending removal" =
  test_additions_are_not_held_back_by_a_removal ()
;;

let%test "authorization: the plan renders additions and removals readably" =
  test_plan_renders_readably ()
;;

let%test "authorization: a target-wide plan covers every domain, never a subset" =
  test_plan_is_target_wide ()
;;
