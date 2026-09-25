(* REFAC-091: the cloud apply sequence, replayed offline through fakes. What is
   asserted is the part that used to be hand-threaded: the bootstrap window is
   removed on every failure while it is open, exactly once, and never when it was
   not opened or already removed. *)

module A = Sol_cli_cloud_apply

type calls =
  { mutable applied_cloud : bool
  ; mutable removals : int
  ; mutable platform_applied : bool
  ; mutable discarded : bool
  ; mutable reports : string list
  }

let fresh () =
  { applied_cloud = false
  ; removals = 0
  ; platform_applied = false
  ; discarded = false
  ; reports = []
  }
;;

(* A fake whose every step succeeds; a test overrides the step it is about. *)
let deps calls : (unit, unit, unit) A.deps =
  { substrate_exists = (fun () -> Ok true)
  ; plan = (fun () -> Ok [])
  ; confirm_ecr_removal = false
  ; apply_plan =
      (fun () ->
        calls.applied_cloud <- true;
        Ok ())
  ; discard_plan = (fun () -> calls.discarded <- true)
  ; outputs = (fun () -> Ok (Some ()))
  ; open_window = (fun () -> Ok (Some ()))
  ; platform_vars = (fun () -> Ok [ "x=1" ])
  ; cloud_ready = (fun () -> Ok ())
  ; with_cluster_access = (fun () f -> f ())
  ; platform_init = (fun () -> Ok ())
  ; platform_installed = (fun () -> false)
  ; apply_prerequisites = (fun () _ -> Ok ())
  ; await_crds = (fun () -> true)
  ; apply_platform =
      (fun () _ ->
        calls.platform_applied <- true;
        Ok ())
  ; await_readiness = (fun () -> [ "platform", Sol_cli_cloud_lifecycle.Established ])
  ; remove_bootstrap_access =
      (fun () ->
        calls.removals <- calls.removals + 1;
        Ok ())
  ; verify_deescalation = (fun () _ -> Ok ())
  ; provisioner_effective = (fun () -> true)
  ; report = (fun line -> calls.reports <- line :: calls.reports)
  }
;;

let failed_with = function
  | A.Applied -> Alcotest.fail "expected a failure, the apply succeeded"
  | A.Apply_failed { failure; cleanup } -> A.failure_to_string failure, cleanup
;;

let cleanup_is expected cleanup =
  Alcotest.(check bool)
    "cleanup"
    true
    (match expected, (cleanup : Sol_cli_cloud_destroy.cleanup) with
     | `Not_needed, Cleanup_not_needed | `Succeeded, Cleanup_succeeded -> true
     | `Failed, Cleanup_failed _ -> true
     | _ -> false)
;;

let test_happy_path () =
  let calls = fresh () in
  (match A.execute ~deps:(deps calls) with
   | A.Applied -> ()
   | A.Apply_failed { failure; _ } -> Alcotest.fail (A.failure_to_string failure));
  Alcotest.(check int) "the window is removed once, by the sequence" 1 calls.removals;
  Alcotest.(check bool) "the saved plan is discarded" true calls.discarded;
  Alcotest.(check bool)
    "Ready is reported last"
    true
    (List.hd calls.reports = "  lifecycle phase: Ready")
;;

let test_failure_in_window_removes_it () =
  let calls = fresh () in
  let deps =
    { (deps calls) with
      apply_platform = (fun () _ -> Error (A.Terraform_failed "terraform exited 1."))
    }
  in
  let message, cleanup = failed_with (A.execute ~deps) in
  Alcotest.(check string) "Terraform's own text" "terraform exited 1." message;
  cleanup_is `Succeeded cleanup;
  Alcotest.(check int) "removed exactly once" 1 calls.removals
;;

(* ADR 0003 invariant 3: an installed platform is re-entered as PlatformUpdating.
   (The phases the sequence refuses are unreachable from [observed_phase], so their
   refusal -- which now removes the window like any failure inside it -- has no
   input that reaches it here.) *)
let test_installed_platform_reenters_as_updating () =
  let calls = fresh () in
  let deps = { (deps calls) with platform_installed = (fun () -> true) } in
  (match A.execute ~deps with
   | A.Applied -> ()
   | A.Apply_failed { failure; _ } -> Alcotest.fail (A.failure_to_string failure));
  Alcotest.(check bool)
    "an installed platform is re-entered as PlatformUpdating"
    true
    (List.mem "  lifecycle phase: PlatformUpdating" calls.reports)
;;

let test_removal_failure_is_not_retried () =
  let calls = fresh () in
  let deps =
    { (deps calls) with
      remove_bootstrap_access =
        (fun () ->
          calls.removals <- calls.removals + 1;
          Error (A.Terraform_failed "terraform exited 1."))
    }
  in
  let _, cleanup = failed_with (A.execute ~deps) in
  cleanup_is `Not_needed cleanup;
  Alcotest.(check int) "the removal is attempted once" 1 calls.removals
;;

let test_failure_after_removal_needs_no_cleanup () =
  let calls = fresh () in
  let deps = { (deps calls) with provisioner_effective = (fun () -> false) } in
  let message, cleanup = failed_with (A.execute ~deps) in
  Alcotest.(check bool)
    "names the provisioner"
    true
    (String.length message > 0 && String.sub message 0 11 = "platform pr");
  cleanup_is `Not_needed cleanup;
  Alcotest.(check int) "no second removal" 1 calls.removals
;;

let test_cleanup_failure_is_reported () =
  let calls = fresh () in
  let deps =
    { (deps calls) with
      cloud_ready = (fun () -> Error "not ready")
    ; remove_bootstrap_access = (fun () -> Error (A.Terraform_failed "exited 1."))
    }
  in
  let message, cleanup = failed_with (A.execute ~deps) in
  Alcotest.(check string) "the primary failure is kept" "not ready" message;
  cleanup_is `Failed cleanup
;;

let test_ecr_removal_refused_before_apply () =
  let calls = fresh () in
  let change =
    { Sol_cli_terraform_plan.address = "aws_ecr_repository.repos[\"a\"]"
    ; resource_type = "aws_ecr_repository"
    ; mode = "managed"
    ; action = Sol_cli_terraform_plan.Delete
    }
  in
  let deps = { (deps calls) with plan = (fun () -> Ok [ change ]) } in
  let _, cleanup = failed_with (A.execute ~deps) in
  cleanup_is `Not_needed cleanup;
  Alcotest.(check bool) "nothing was applied" false calls.applied_cloud;
  Alcotest.(check int) "no window to remove" 0 calls.removals;
  Alcotest.(check bool) "the plan is still discarded" true calls.discarded;
  let confirmed =
    A.execute
      ~deps:{ deps with confirm_ecr_removal = true; plan = (fun () -> Ok [ change ]) }
  in
  Alcotest.(check bool)
    "confirmed, the apply proceeds"
    true
    (match confirmed with
     | A.Applied -> true
     | A.Apply_failed _ -> false)
;;

let test_cloud_apply_failure_opens_no_window () =
  let calls = fresh () in
  let deps =
    { (deps calls) with apply_plan = (fun () -> Error (A.Terraform_failed "exited 1.")) }
  in
  let _, cleanup = failed_with (A.execute ~deps) in
  cleanup_is `Not_needed cleanup;
  Alcotest.(check int) "no removal" 0 calls.removals
;;

let test_unknown_substrate_fails_closed () =
  let calls = fresh () in
  let deps =
    { (deps calls) with substrate_exists = (fun () -> Error "state unreadable") }
  in
  let message, _ = failed_with (A.execute ~deps) in
  Alcotest.(check string) "the reason" "state unreadable" message;
  Alcotest.(check bool) "nothing was applied" false calls.applied_cloud
;;

let test_fresh_target_reports_bootstrap () =
  let calls = fresh () in
  let deps = { (deps calls) with substrate_exists = (fun () -> Ok false) } in
  ignore (A.execute ~deps);
  Alcotest.(check bool)
    "CloudBootstrap reported"
    true
    (List.mem "  lifecycle phase: CloudBootstrap" calls.reports)
;;

let () =
  Alcotest.run
    "cloud_apply"
    [ ( "execute"
      , [ Alcotest.test_case "happy path" `Quick test_happy_path
        ; Alcotest.test_case
            "failure in the window removes it"
            `Quick
            test_failure_in_window_removes_it
        ; Alcotest.test_case
            "installed platform re-enters as updating"
            `Quick
            test_installed_platform_reenters_as_updating
        ; Alcotest.test_case
            "removal failure is not retried"
            `Quick
            test_removal_failure_is_not_retried
        ; Alcotest.test_case
            "failure after removal needs no cleanup"
            `Quick
            test_failure_after_removal_needs_no_cleanup
        ; Alcotest.test_case
            "cleanup failure is reported"
            `Quick
            test_cleanup_failure_is_reported
        ; Alcotest.test_case
            "ECR removal refused before apply"
            `Quick
            test_ecr_removal_refused_before_apply
        ; Alcotest.test_case
            "cloud apply failure opens no window"
            `Quick
            test_cloud_apply_failure_opens_no_window
        ; Alcotest.test_case
            "unknown substrate fails closed"
            `Quick
            test_unknown_substrate_fails_closed
        ; Alcotest.test_case
            "fresh target reports CloudBootstrap"
            `Quick
            test_fresh_target_reports_bootstrap
        ] )
    ]
;;
