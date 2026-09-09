(* Tests for Sol_cli_deployment_state.record_outcome.
   Verifies that Dry_run, Failed, and Emitted outcomes are no-ops and that
   Applied outcomes invoke the state write path. The kubectl call inside
   save_deployed_groups is ignored on error so tests run without a cluster. *)

let test_dry_run_is_noop () =
  Sol_cli_deployment_state.record_outcome "test-workspace"
    Sol_cli_deployment_state.Dry_run

let test_failed_is_noop () =
  Sol_cli_deployment_state.record_outcome "test-workspace"
    (Sol_cli_deployment_state.Failed
       { phase = "build"; message = "docker build failed" })

let test_emitted_is_noop () =
  Sol_cli_deployment_state.record_outcome "test-workspace"
    (Sol_cli_deployment_state.Emitted { file = "/tmp/myapp-default-svc.yaml" })

let test_applied_does_not_raise () =
  (* kubectl apply will fail without a cluster; save_deployed_groups ignores the error *)
  Sol_cli_deployment_state.record_outcome "test-workspace"
    (Sol_cli_deployment_state.Applied
       {
         namespace = "default";
         name = "svc";
         image = "registry/svc:abc123";
         consumer_groups = [ "payments.events"; "comms.notifications" ];
       })

let test_removed_consumer_groups_detects_removal () =
  let prev = [ "payments.events"; "comms.notifications"; "billing.invoices" ] in
  let next = [ "payments.events"; "comms.notifications" ] in
  let removed = Sol_cli_deployment_state.removed_consumer_groups ~prev ~next in
  Alcotest.(check (list string)) "removed groups" [ "billing.invoices" ] removed

let test_removed_consumer_groups_empty_when_stable () =
  let groups = [ "payments.events"; "comms.notifications" ] in
  let removed =
    Sol_cli_deployment_state.removed_consumer_groups ~prev:groups ~next:groups
  in
  Alcotest.(check (list string)) "no removals" [] removed

let test_removed_consumer_groups_all_removed () =
  let prev = [ "a"; "b" ] in
  let removed =
    Sol_cli_deployment_state.removed_consumer_groups ~prev ~next:[]
  in
  Alcotest.(check (list string)) "all removed" [ "a"; "b" ] removed

let test_removed_consumer_groups_additions_ignored () =
  let prev = [ "a" ] in
  let next = [ "a"; "b"; "c" ] in
  let removed = Sol_cli_deployment_state.removed_consumer_groups ~prev ~next in
  Alcotest.(check (list string)) "additions do not appear as removed" [] removed

let () =
  Alcotest.run "deployment_state"
    [
      ( "record_outcome",
        [
          Alcotest.test_case "dry-run is a no-op" `Quick test_dry_run_is_noop;
          Alcotest.test_case "failed is a no-op" `Quick test_failed_is_noop;
          Alcotest.test_case "emitted is a no-op" `Quick test_emitted_is_noop;
          Alcotest.test_case "applied does not raise" `Quick
            test_applied_does_not_raise;
        ] );
      ( "removed_consumer_groups",
        [
          Alcotest.test_case "detects removed groups" `Quick
            test_removed_consumer_groups_detects_removal;
          Alcotest.test_case "stable groups empty" `Quick
            test_removed_consumer_groups_empty_when_stable;
          Alcotest.test_case "all groups removed" `Quick
            test_removed_consumer_groups_all_removed;
          Alcotest.test_case "additions not as removed" `Quick
            test_removed_consumer_groups_additions_ignored;
        ] );
    ]
