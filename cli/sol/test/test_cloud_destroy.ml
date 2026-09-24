(* Offline tests for the destroy execution core (HARDEN-004 step 2 / REFAC-091).

   Two things are pinned here and they are deliberately different claims:

   - the typed inventory is built from the real Terraform representation
     (addresses, child modules, ids/regions) and distinguishes valid absence
     from valid representation from UNKNOWN. UNKNOWN is never absence.
   - the execution core derives its behaviour from that inventory, never from
     the install-time outputs contract, and its elevated-access cleanup runs on
     every path -- including a failure to enable or a failure of the operation
     the access was opened for. A cleanup failure is evidence, not silence.

   Every provider operation is a fake, so none of this needs terraform, gcloud,
   aws, or a network. *)

open Sol_cli_cloud_destroy

let contains re s =
  try
    ignore (Str.search_forward re s 0);
    true
  with
  | Not_found -> false
;;

let show_json_resources resources =
  Printf.sprintf {|{"values":{"root_module":{"resources":[%s]}}}|} resources
;;

let gcp_cluster =
  {|{"address":"google_container_cluster.main","type":"google_container_cluster","values":{"deletion_protection":true,"self_link":"https://container.googleapis.com/v1/projects/p/locations/us-central1/clusters/c","project":"sol-qualification","location":"us-central1"}}|}
;;

(* ── Inventory ───────────────────────────────────────────────────────────── *)

let test_empty_state () =
  let state = inventory_of_show_json {|{"values":{"root_module":{"resources":[]}}}|} in
  Alcotest.(check bool) "empty is a valid absence" true (state = State_empty);
  Alcotest.(check bool)
    "empty substrate is absent"
    true
    (substrate_presence state = Substrate_absent);
  Alcotest.(check (list string)) "no addresses" [] (addresses state)
;;

let test_missing_values_is_empty () =
  (* FND-0048: a missing `values` is the empty state, not a read failure. *)
  List.iter
    (fun json ->
       Alcotest.(check bool)
         "absent values is a valid empty state"
         true
         (inventory_of_show_json json = State_empty))
    [ {|{}|}
    ; {|{"format_version":"1.0"}|}
    ; {|{"values":null}|}
    ; {|{"values":{"root_module":{}}}|}
    ]
;;

let test_represented_identity () =
  match inventory_of_show_json (show_json_resources gcp_cluster) with
  | State_represented [ resource ] ->
    Alcotest.(check string)
      "real address"
      "google_container_cluster.main"
      resource.address;
    Alcotest.(check string) "kind" "google_container_cluster" resource.kind;
    Alcotest.(check (option string))
      "self-link preferred"
      (Some
         "https://container.googleapis.com/v1/projects/p/locations/us-central1/clusters/c")
      resource.provider_id;
    Alcotest.(check (option string)) "project" (Some "sol-qualification") resource.project;
    Alcotest.(check (option string)) "location" (Some "us-central1") resource.region;
    Alcotest.(check (option bool))
      "deletion guard"
      (Some true)
      resource.deletion_protection
  | other ->
    Alcotest.failf
      "expected one represented resource, got %s"
      (match other with
       | State_empty -> "State_empty"
       | State_represented _ -> "State_represented"
       | State_unreadable message -> "State_unreadable " ^ message)
;;

let test_null_protection_is_not_an_error () =
  (* FND-0048: a benign null must not surface as "could not read state". *)
  let json =
    show_json_resources
      {|{"address":"google_sql_database_instance.postgres","type":"google_sql_database_instance","values":{"deletion_protection":null}}|}
  in
  match inventory_of_show_json json with
  | State_represented [ resource ] ->
    Alcotest.(check (option bool))
      "null guard reads as absent, not an error"
      None
      resource.deletion_protection
  | _ -> Alcotest.fail "expected a represented resource with a null guard"
;;

let test_child_module_address_preserved () =
  let json =
    {|{"values":{"root_module":{"resources":[],"child_modules":[{"address":"module.net","resources":[{"address":"module.net.google_compute_network.vpc","type":"google_compute_network","values":{"self_link":"https://x/vpc","project":"p","region":"us-central1"}}]}]}}}|}
  in
  match inventory_of_show_json json with
  | State_represented [ resource ] ->
    Alcotest.(check string)
      "child-module address verbatim"
      "module.net.google_compute_network.vpc"
      resource.address;
    Alcotest.(check (option string))
      "provider id"
      (Some "https://x/vpc")
      resource.provider_id
  | _ -> Alcotest.fail "a child-module resource must be represented with its real address"
;;

let test_same_type_instances_are_distinct () =
  let json =
    show_json_resources
      {|{"address":"google_sql_database_instance.postgres","type":"google_sql_database_instance","values":{"deletion_protection":true}},{"address":"google_sql_database_instance.replica","type":"google_sql_database_instance","values":{"deletion_protection":false}}|}
  in
  match inventory_of_show_json json with
  | State_represented resources ->
    Alcotest.(check int) "both instances represented" 2 (List.length resources);
    let guard address =
      Option.bind (find_address (State_represented resources) address) (fun r ->
        r.deletion_protection)
    in
    Alcotest.(check (option bool))
      "first instance keeps its own guard"
      (Some true)
      (guard "google_sql_database_instance.postgres");
    Alcotest.(check (option bool))
      "second instance keeps its own guard"
      (Some false)
      (guard "google_sql_database_instance.replica")
  | _ -> Alcotest.fail "expected two represented resources"
;;

let test_unreadable_is_unknown () =
  List.iter
    (fun json ->
       match inventory_of_show_json json with
       | State_unreadable _ ->
         Alcotest.(check bool)
           "unreadable is not absence"
           true
           (substrate_presence (inventory_of_show_json json) = Substrate_unknown)
       | State_empty | State_represented _ ->
         Alcotest.failf "expected UNKNOWN for %s" json)
    [ "not json at all"
    ; {|{"values":42}|}
    ; show_json_resources {|{"type":"google_container_cluster"}|} (* no address *)
    ; show_json_resources
        {|{"address":"x.y","type":"z","values":{"deletion_protection":"yes"}}|}
    ]
;;

let test_zone_reduces_to_region () =
  let json =
    show_json_resources
      {|{"address":"google_compute_instance.node","type":"google_compute_instance","values":{"zone":"us-central1-a","id":"123"}}|}
  in
  match inventory_of_show_json json with
  | State_represented [ resource ] ->
    Alcotest.(check (option string))
      "region from zone"
      (Some "us-central1")
      resource.region
  | _ -> Alcotest.fail "expected a represented resource"
;;

(* ── Execution core ──────────────────────────────────────────────────────── *)

(* A recording set of fakes. Every operation is counted, so "was cleanup
   attempted?" is an observation rather than an inference. *)
type calls =
  { mutable credentials : int
  ; mutable init : int
  ; mutable observe : int
  ; mutable prepare : state_read list
  ; mutable reconcile : int
  ; mutable platform : int
  ; mutable remove : int
  ; mutable substrate : int
  ; mutable verify : int
  }

let fake_deps
      ?(state = Ok {|{}|})
      ?(outputs = Outputs_available)
      ?(prepare = fun ~state:_ -> Sol_cli_cloud_lifecycle.Nothing_to_prepare)
      ?(reconcile = fun () -> Ok ())
      ?(platform = fun () -> Ok ())
      ?(remove = fun () -> Ok ())
      ?(destroy_substrate = fun () -> Ok ())
      ?(verify_absent = fun () -> Ok ())
      ()
  =
  let calls =
    { credentials = 0
    ; init = 0
    ; observe = 0
    ; prepare = []
    ; reconcile = 0
    ; platform = 0
    ; remove = 0
    ; substrate = 0
    ; verify = 0
    }
  in
  let deps =
    { require_credentials =
        (fun () ->
          calls.credentials <- calls.credentials + 1;
          Ok ())
    ; terraform_init =
        (fun () ->
          calls.init <- calls.init + 1;
          Ok ())
    ; observe_state =
        (fun () ->
          calls.observe <- calls.observe + 1;
          state)
    ; cloud_outputs = (fun () -> outputs)
    ; prepare =
        (fun ~state ->
          calls.prepare <- state :: calls.prepare;
          prepare ~state)
    ; reconcile_and_enable =
        (fun () ->
          calls.reconcile <- calls.reconcile + 1;
          reconcile ())
    ; destroy_platform =
        (fun () ->
          calls.platform <- calls.platform + 1;
          platform ())
    ; remove_elevated_access =
        (fun () ->
          calls.remove <- calls.remove + 1;
          remove ())
    ; observe_window_before = (fun () -> Ok ())
    ; verify_window_after = (fun () -> Ok ())
    ; destroy_substrate =
        (fun () ->
          calls.substrate <- calls.substrate + 1;
          destroy_substrate ())
    ; verify_absent =
        (fun () ->
          calls.verify <- calls.verify + 1;
          verify_absent ())
    ; report = (fun _ -> ())
    ; warn = (fun _ -> ())
    }
  in
  deps, calls
;;

let test_empty_state_destroys_without_outputs () =
  (* Test 1 of the contract: an empty inventory is empty, and missing install
     outputs do not fail the destroy. *)
  let deps, calls =
    fake_deps ~state:(Ok {|{}|}) ~outputs:(Outputs_unavailable "no outputs") ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { substrate; cleanup; _ } ->
     Alcotest.(check bool) "empty substrate is absent" true (substrate = Substrate_absent);
     Alcotest.(check bool)
       "no elevated access was opened"
       true
       (cleanup = Cleanup_not_needed)
   | Destroy_blocked { guarantee; _ } ->
     Alcotest.failf "an empty, output-less target must not be blocked: %s" guarantee
   | Destroy_failed { failure; _ } ->
     Alcotest.failf
       "an empty, output-less target must still destroy: %s"
       (failure_message failure));
  Alcotest.(check int) "substrate destroy ran" 1 calls.substrate;
  Alcotest.(check int) "no reconciliation on an empty state" 0 calls.reconcile;
  Alcotest.(check int) "absence verified" 1 calls.verify
;;

let test_half_built_state_is_destroyable () =
  (* Test 2: a state representing a subset of the configured resources, with no
     usable install outputs, must still be destroyable -- and the preparation
     must be handed the represented state. *)
  let state = show_json_resources gcp_cluster in
  let deps, calls =
    fake_deps ~state:(Ok state) ~outputs:(Outputs_unavailable "partial outputs") ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { substrate; _ } ->
     Alcotest.(check bool) "the subset is represented" true (substrate = Substrate_present)
   | Destroy_blocked { guarantee; _ } ->
     Alcotest.failf "a half-built target must not be blocked: %s" guarantee
   | Destroy_failed { failure; _ } ->
     Alcotest.failf
       "a half-built target must be destroyable: %s"
       (failure_message failure));
  Alcotest.(check int) "preparation ran once" 1 (List.length calls.prepare);
  Alcotest.(check bool)
    "preparation saw the represented state"
    true
    (match calls.prepare with
     | [ State_represented _ ] -> true
     | _ -> false);
  Alcotest.(check int) "substrate destroy ran" 1 calls.substrate
;;

let test_partial_outputs_never_refuse () =
  (* Test 3: no install-contract parse failure can prevent destruction. *)
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~outputs:(Outputs_unavailable "invalid GCP Terraform output JSON: expected object")
      ()
  in
  let outcome = execute ~deps in
  Alcotest.(check int) "exit code is success" 0 (exit_code outcome);
  Alcotest.(check int)
    "the platform teardown was not wired from bad outputs"
    0
    calls.platform;
  Alcotest.(check int) "the substrate was still destroyed" 1 calls.substrate
;;

let test_state_read_failure_is_not_absence () =
  (* Test 6: a state read/process failure is UNKNOWN, and the destroy does not
     read it as "the substrate is gone". *)
  let deps, calls = fake_deps ~state:(Error "terraform show exited 1") () in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { substrate; _ } ->
     Alcotest.(check bool) "UNKNOWN, not absent" true (substrate = Substrate_unknown)
   | Destroy_blocked { guarantee; _ } ->
     Alcotest.failf "an unreadable state must not be blocked: %s" guarantee
   | Destroy_failed { failure; _ } ->
     Alcotest.failf
       "an unreadable state must not block destruction: %s"
       (failure_message failure));
  Alcotest.(check int) "the destroy was still attempted" 1 calls.substrate;
  Alcotest.(check int)
    "no constructive whole-root apply on an unreadable state"
    0
    calls.reconcile
;;

let test_elevated_access_opened_and_removed () =
  let deps, calls =
    fake_deps ~state:(Ok (show_json_resources gcp_cluster)) ~outputs:Outputs_available ()
  in
  let outcome = execute ~deps in
  Alcotest.(check int) "access enabled" 1 calls.reconcile;
  Alcotest.(check int) "platform torn down under the access" 1 calls.platform;
  Alcotest.(check int) "access removed" 1 calls.remove;
  match outcome with
  | Destroy_succeeded { cleanup; _ } ->
    Alcotest.(check bool)
      "cleanup recorded as succeeding"
      true
      (cleanup = Cleanup_succeeded)
  | Destroy_blocked { guarantee; _ } -> Alcotest.failf "unexpected block: %s" guarantee
  | Destroy_failed { failure; _ } ->
    Alcotest.failf "expected success: %s" (failure_message failure)
;;

let test_protected_operation_failure_still_removes () =
  (* Test 7: the operation the access was opened for fails; removal is still
     attempted through the bracket. *)
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~reconcile:(fun () -> Ok ())
      ~platform:(fun () -> Error "platform destroy refused")
      ~remove:(fun () -> Ok ())
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_failed { failure = Platform_destroy_failed message; cleanup; _ } ->
     Alcotest.(check string)
       "the platform failure is reported"
       "platform destroy refused"
       message;
     Alcotest.(check bool) "the removal succeeded" true (cleanup = Cleanup_succeeded)
   | _ -> Alcotest.fail "expected a platform-destroy failure carrying its cleanup");
  Alcotest.(check int) "removal was attempted after the failure" 1 calls.remove
;;

let test_skipped_teardown_is_a_degradation () =
  (* Step 4 + the Step-2 guarantee: the reconciliation apply obtains the authority
     the platform teardown needs. When it fails, the protected operation is skipped
     -- a degradation, not a refusal, because the substrate destroy needs no cluster
     authority -- and removal is still attempted. *)
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~reconcile:(fun () -> Error "reconciliation apply failed")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations = [ message ]; cleanup = Cleanup_succeeded; _ } ->
     Alcotest.(check bool)
       "the skipped teardown says what it was waiting on"
       true
       (contains (Str.regexp_string "bootstrap authority") message)
   | _ -> Alcotest.fail "a failed reconciliation must degrade, not refuse the destroy");
  Alcotest.(check int) "the platform operation did not run" 0 calls.platform;
  Alcotest.(check int) "removal was still attempted" 1 calls.remove;
  Alcotest.(check int) "the substrate destroy still ran" 1 calls.substrate;
  Alcotest.(check int) "degraded success exits 3" exit_degraded (exit_code outcome)
;;

let test_platform_failure_is_not_a_degradation () =
  (* "We could not obtain the authority, so the protected operation could not run"
     and "the protected operation ran and failed" are different consequences. Only
     the first is a degradation. *)
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~platform:(fun () -> Error "platform destroy exited 1")
      ()
  in
  let outcome = execute ~deps in
  match outcome with
  | Destroy_failed { failure = Platform_destroy_failed message; degradations = []; _ } ->
    Alcotest.(check string)
      "the platform failure stands"
      "platform destroy exited 1"
      message
  | _ -> Alcotest.fail "a failed protected operation is a failure, not a degradation"
;;

let test_skipped_teardown_and_cleanup_failure_are_both_preserved () =
  (* The three facts of a degraded-and-dirty run stay separate: the skipped
     protected operation, the primary failure the cleanup failure stands for, and
     the cleanup evidence itself. *)
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~reconcile:(fun () -> Error "no authority")
      ~remove:(fun () -> Error "cleanup refused")
      ()
  in
  let outcome = execute ~deps in
  match outcome with
  | Destroy_failed
      { failure = Elevated_access_not_removed message
      ; degradations = [ degraded ]
      ; cleanup = Cleanup_failed cleanup_message
      } ->
    Alcotest.(check string) "the removal failure is the failure" "cleanup refused" message;
    Alcotest.(check string)
      "and is carried as cleanup evidence"
      "cleanup refused"
      cleanup_message;
    Alcotest.(check bool)
      "and the skipped teardown is still there"
      true
      (contains (Str.regexp_string "bootstrap authority") degraded)
  | _ -> Alcotest.fail "primary, cleanup and degradation facts must all be preserved"
;;

let test_cleanup_failure_is_not_replaced_by_success () =
  (* Test 8: a cleanup failure on the otherwise-successful path is the failure,
     and it is carried, not swallowed. *)
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~remove:(fun () -> Error "terraform exited 1: access removal failed")
      ()
  in
  let outcome = execute ~deps in
  match outcome with
  | Destroy_failed { failure = Elevated_access_not_removed message; cleanup; _ } ->
    Alcotest.(check bool)
      "the removal failure is the message"
      true
      (contains (Str.regexp "access removal failed") message);
    Alcotest.(check bool)
      "the cleanup failure is preserved as evidence"
      true
      (match cleanup with
       | Cleanup_failed _ -> true
       | _ -> false)
  | _ -> Alcotest.fail "a cleanup failure must not be reported as success"
;;

let test_cleanup_failure_preserved_when_operation_fails () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~platform:(fun () -> Error "platform destroy refused")
      ~remove:(fun () -> Error "removal refused too")
      ()
  in
  let outcome = execute ~deps in
  match outcome with
  | Destroy_failed
      { failure = Platform_destroy_failed _; cleanup = Cleanup_failed message; _ } ->
    Alcotest.(check string)
      "the cleanup failure is preserved"
      "removal refused too"
      message
  | _ -> Alcotest.fail "expected the platform failure with its cleanup evidence"
;;

(* ── Failure policy (HARDEN-004 step 4) ────────────────────────────────────

   "Preparation failed" and "destruction must not proceed" are different claims.
   The preparation declares the consequence of its own failure (DEC-033), and these
   pin both directions so neither can drift into the other. *)

let continue_failure reason =
  Sol_cli_cloud_lifecycle.Preparation_failed
    { reason; policy = Sol_cli_cloud_lifecycle.Continue_to_destroy }
;;

let block_failure reason =
  Sol_cli_cloud_lifecycle.Preparation_failed
    { reason; policy = Sol_cli_cloud_lifecycle.Block_destroy }
;;

let test_continue_preparation_failure_destroys () =
  (* Regression 1 + 3: a best-effort preparation fails; the destroy proceeds, and
     the failure stays visible rather than being erased by the success. *)
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        continue_failure "the deletion guards could not be lowered")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { preparation = Nothing_prepared; degradations = [ message ]; _ }
     ->
     Alcotest.(check string)
       "the preparation failure is preserved as evidence"
       "preparation: the deletion guards could not be lowered"
       message
   | _ ->
     Alcotest.fail
       "a Continue_to_destroy preparation failure must let destruction proceed, and stay \
        visible");
  Alcotest.(check int) "the substrate was destroyed" 1 calls.substrate;
  Alcotest.(check int)
    "a degraded destroy is not a clean success"
    exit_degraded
    (exit_code outcome)
;;

let test_block_preparation_failure_blocks_destruction () =
  (* Regression 4 + 5: a Block_destroy preparation names the guarantee the target
     declared, and destruction does not run at all. *)
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        block_failure
          "the target's destroy_retention is final-snapshot, so its declared retention \
           guarantee could not be established before destroying: snapshot refused")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_blocked { guarantee } ->
     Alcotest.(check bool)
       "the retention guarantee is identified as the blocker"
       true
       (contains (Str.regexp_string "destroy_retention is final-snapshot") guarantee)
   | _ -> Alcotest.fail "a Block_destroy preparation failure must block destruction");
  Alcotest.(check int) "the substrate was not destroyed" 0 calls.substrate;
  Alcotest.(check int)
    "a blocked destroy exits as a failure"
    exit_failure
    (exit_code outcome)
;;

let test_clean_destruction_is_clean () =
  (* Regression 10. *)
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ -> Sol_cli_cloud_lifecycle.Prepared Gcp_prepared)
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { preparation = Gcp_prepared; degradations = []; _ } -> ()
   | _ -> Alcotest.fail "a clean preparation and a clean destroy must be a clean success");
  Alcotest.(check int) "the substrate was destroyed" 1 calls.substrate;
  Alcotest.(check int) "clean success exits 0" exit_clean (exit_code outcome)
;;

let test_degradation_preserved_when_destroy_fails () =
  (* Regression 8: a degraded preparation is preserved even when a later step fails;
     neither fact may collapse into the other. *)
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ -> continue_failure "guards not lowered")
      ~destroy_substrate:(fun () -> Error "terraform destroy exited 1")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_failed
       { failure = Substrate_destroy_failed message; degradations = [ degraded ]; _ } ->
     Alcotest.(check string)
       "the destroy failure stands"
       "terraform destroy exited 1"
       message;
     Alcotest.(check string)
       "the preparation degradation is preserved separately"
       "preparation: guards not lowered"
       degraded
   | _ ->
     Alcotest.fail "a failed destroy must preserve the earlier preparation degradation");
  Alcotest.(check int)
    "a failed destroy exits as a failure"
    exit_failure
    (exit_code outcome)
;;

let test_unknown_state_is_not_absence_and_not_silent () =
  (* Regression 11: an unreadable state is not absence, and it does not silently
     become a best-effort preparation failure -- the preparation runs (it is not
     skipped as "nothing to prepare"), the substrate stays UNKNOWN, and the failure
     is reported. *)
  let deps, calls =
    fake_deps
      ~state:(Error "terraform show failed with exit 1")
      ~prepare:(fun ~state:_ -> continue_failure "the target's state could not be read")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { substrate = Substrate_unknown; degradations = [ _ ]; _ } -> ()
   | _ -> Alcotest.fail "UNKNOWN must remain UNKNOWN and be reported, never absence");
  Alcotest.(check int)
    "the preparation was attempted, not skipped as empty"
    1
    (List.length calls.prepare);
  Alcotest.(check int) "the substrate destroy still ran" 1 calls.substrate
;;

(* Regression 12 / step 3 preserved: a refused plan is an outcome, not permission to
   weaken the assertion, and the *policy* controls only what follows. Composed here
   with the real step-3 mechanism, the way [cmd_cloud_tf] wires it. *)
let test_refused_plan_is_a_continue_failure () =
  let applied = ref 0 in
  let policy =
    { Sol_cli_terraform_plan.phase = "guard-preparation"
    ; rules =
        [ { matches = [ Sol_cli_terraform_plan.Exact "google_container_cluster.main" ]
          ; allows = [ Sol_cli_terraform_plan.Update ]
          ; reason = ""
          }
        ]
    }
  in
  let refused_plan =
    {|{"resource_changes":[{"address":"google_container_cluster.main","type":"google_container_cluster","mode":"managed","change":{"actions":["create"]}}]}|}
  in
  let preparation =
    match
      Sol_cli_terraform_plan.guarded_apply
        ~policy
        ~plan:(fun () -> Ok "/tmp/plan")
        ~show_plan:(fun _ -> Ok refused_plan)
        ~apply_plan:(fun _ ->
          applied := !applied + 1;
          Ok ())
        ()
    with
    | Ok () -> Sol_cli_cloud_lifecycle.Nothing_to_prepare
    | Error failure ->
      continue_failure (Sol_cli_terraform_plan.apply_failure_to_string failure)
  in
  Alcotest.(check int) "the unsafe apply never ran" 0 !applied;
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ -> preparation)
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations = [ _ ]; _ } -> ()
   | _ -> Alcotest.fail "a refused plan must let destruction continue, not block it");
  Alcotest.(check int) "the substrate destroy still ran" 1 calls.substrate
;;

let test_substrate_destroy_failure () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~destroy_substrate:(fun () -> Error "terraform destroy exited 1")
      ()
  in
  let outcome = execute ~deps in
  match outcome with
  | Destroy_failed { failure = Substrate_destroy_failed _; _ } -> ()
  | _ -> Alcotest.fail "expected the substrate destroy failure"
;;

let test_absent_state_with_outputs_skips_teardown () =
  let deps, calls = fake_deps ~state:(Ok {|{}|}) ~outputs:Outputs_available () in
  let outcome = execute ~deps in
  Alcotest.(check int) "exit code is success" 0 (exit_code outcome);
  Alcotest.(check int)
    "no reconciliation without a represented substrate"
    0
    calls.reconcile;
  Alcotest.(check int)
    "no platform teardown without a represented substrate"
    0
    calls.platform;
  Alcotest.(check int) "the substrate destroy still ran" 1 calls.substrate
;;

(* ── Plan assertion composed with the execution core (HARDEN-004 step 3) ──── *)

let binding =
  Sol_cli_terraform_plan.Exact
    "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
;;

let guard_json =
  {|{"resource_changes":[{"address":"google_container_cluster.main","type":"google_container_cluster","mode":"managed","change":{"actions":["create"]}}]}|}
;;

let refused_apply plan_ref policy plan_json () =
  match
    Sol_cli_terraform_plan.guarded_apply
      ~policy
      ~plan:(fun () -> Ok "/tmp/plan")
      ~show_plan:(fun _ -> Ok plan_json)
      ~apply_plan:(fun _ ->
        plan_ref := !plan_ref + 1;
        Ok ())
      ()
  with
  | Ok () -> Ok ()
  | Error failure -> Error (Sol_cli_terraform_plan.apply_failure_to_string failure)
;;

(* Step 3's property, unchanged by step 4: if the assertion refuses a plan, the
   corresponding apply is never invoked. Step 4 changes only what *follows* -- the
   refusal is a degradation, so the substrate destroy still runs, which is exactly
   the half-built target this path exists to keep destroyable. *)
let test_refused_reconciliation_never_applies () =
  let open Sol_cli_terraform_plan in
  let applied = ref 0 in
  let policy =
    { phase = "destroy-reconciliation"
    ; rules = [ { matches = [ binding ]; allows = [ Update ]; reason = "" } ]
    }
  in
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~reconcile:(refused_apply applied policy guard_json)
      ()
  in
  let outcome = execute ~deps in
  Alcotest.(check int) "the refused apply was never invoked" 0 !applied;
  (match outcome with
   | Destroy_succeeded { degradations = [ _ ]; cleanup = Cleanup_succeeded; _ } -> ()
   | _ -> Alcotest.fail "a refused plan must degrade the destroy, never be executed");
  Alcotest.(check int) "removal was still attempted" 1 calls.remove;
  Alcotest.(check int) "the substrate destroy still ran" 1 calls.substrate
;;

(* "Cleanup" is a name, not a safety property: a removal whose plan is refused
   does not run, is not reported as a successful cleanup, and leaves the outcome
   saying the elevated access may remain. *)
let test_refused_removal_is_not_success () =
  let open Sol_cli_terraform_plan in
  let applied = ref 0 in
  let policy =
    { phase = "bootstrap-access-removal"
    ; rules = [ { matches = [ binding ]; allows = [ Update ]; reason = "" } ]
    }
  in
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~remove:(refused_apply applied policy guard_json)
      ()
  in
  let outcome = execute ~deps in
  Alcotest.(check int) "the refused cleanup apply was never invoked" 0 !applied;
  (match outcome with
   | Destroy_failed
       { failure = Elevated_access_not_removed _; cleanup = Cleanup_failed _; _ } -> ()
   | _ -> Alcotest.fail "a refused removal must not be reported as a successful cleanup");
  Alcotest.(check int) "the substrate destroy did not run" 0 calls.substrate
;;

let () =
  Alcotest.run
    "cloud_destroy"
    [ ( "inventory"
      , [ Alcotest.test_case "empty state" `Quick test_empty_state
        ; Alcotest.test_case "missing values is empty" `Quick test_missing_values_is_empty
        ; Alcotest.test_case "represented identity" `Quick test_represented_identity
        ; Alcotest.test_case "null protection" `Quick test_null_protection_is_not_an_error
        ; Alcotest.test_case
            "child-module address"
            `Quick
            test_child_module_address_preserved
        ; Alcotest.test_case
            "same type, distinct instances"
            `Quick
            test_same_type_instances_are_distinct
        ; Alcotest.test_case "unreadable is UNKNOWN" `Quick test_unreadable_is_unknown
        ; Alcotest.test_case "zone reduces to region" `Quick test_zone_reduces_to_region
        ] )
    ; ( "execute"
      , [ Alcotest.test_case
            "empty state without outputs"
            `Quick
            test_empty_state_destroys_without_outputs
        ; Alcotest.test_case
            "half-built state"
            `Quick
            test_half_built_state_is_destroyable
        ; Alcotest.test_case
            "partial outputs never refuse"
            `Quick
            test_partial_outputs_never_refuse
        ; Alcotest.test_case
            "state read failure is not absence"
            `Quick
            test_state_read_failure_is_not_absence
        ; Alcotest.test_case
            "elevated access opened/removed"
            `Quick
            test_elevated_access_opened_and_removed
        ; Alcotest.test_case
            "protected-operation failure still removes"
            `Quick
            test_protected_operation_failure_still_removes
        ; Alcotest.test_case
            "skipped teardown is a degradation"
            `Quick
            test_skipped_teardown_is_a_degradation
        ; Alcotest.test_case
            "platform failure is not a degradation"
            `Quick
            test_platform_failure_is_not_a_degradation
        ; Alcotest.test_case
            "skipped teardown + cleanup failure preserved"
            `Quick
            test_skipped_teardown_and_cleanup_failure_are_both_preserved
        ; Alcotest.test_case
            "cleanup failure is not success"
            `Quick
            test_cleanup_failure_is_not_replaced_by_success
        ; Alcotest.test_case
            "cleanup failure preserved"
            `Quick
            test_cleanup_failure_preserved_when_operation_fails
        ; Alcotest.test_case
            "substrate destroy failure"
            `Quick
            test_substrate_destroy_failure
        ; Alcotest.test_case
            "absent state with outputs"
            `Quick
            test_absent_state_with_outputs_skips_teardown
        ] )
    ; ( "failure policy"
      , [ Alcotest.test_case
            "continue failure destroys"
            `Quick
            test_continue_preparation_failure_destroys
        ; Alcotest.test_case
            "block failure blocks destruction"
            `Quick
            test_block_preparation_failure_blocks_destruction
        ; Alcotest.test_case
            "clean destruction is clean"
            `Quick
            test_clean_destruction_is_clean
        ; Alcotest.test_case
            "degradation preserved when destroy fails"
            `Quick
            test_degradation_preserved_when_destroy_fails
        ; Alcotest.test_case
            "UNKNOWN is not absence and not silent"
            `Quick
            test_unknown_state_is_not_absence_and_not_silent
        ; Alcotest.test_case
            "refused plan is a continue failure"
            `Quick
            test_refused_plan_is_a_continue_failure
        ] )
    ; ( "plan assertion"
      , [ Alcotest.test_case
            "refused reconciliation never applies"
            `Quick
            test_refused_reconciliation_never_applies
        ; Alcotest.test_case
            "refused removal is not success"
            `Quick
            test_refused_removal_is_not_success
        ] )
    ]
;;
