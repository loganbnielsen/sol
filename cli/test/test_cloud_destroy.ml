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
  {|{"address":"google_container_cluster.main","type":"google_container_cluster","values":{"name":"c","deletion_protection":true,"self_link":"https://container.googleapis.com/v1/projects/p/locations/us-central1/clusters/c","project":"sol-qualification","location":"us-central1"}}|}
;;

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
      "the name Terraform recorded"
      (Some "c")
      resource.name;
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
    {|{"values":{"root_module":{"resources":[],"child_modules":[{"address":"module.net","resources":[{"address":"module.net.google_compute_network.vpc","type":"google_compute_network","values":{"name":"vpc","self_link":"https://x/vpc","project":"p","region":"us-central1"}}]}]}}}|}
  in
  match inventory_of_show_json json with
  | State_represented [ resource ] ->
    Alcotest.(check string)
      "child-module address verbatim"
      "module.net.google_compute_network.vpc"
      resource.address;
    Alcotest.(check (option string))
      "its name, as Terraform recorded it"
      (Some "vpc")
      resource.name
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
    ; show_json_resources {|{"type":"google_container_cluster"}|}
    ; show_json_resources
        {|{"address":"x.y","type":"z","values":{"deletion_protection":"yes"}}|}
    ]
;;

let test_identifier_captured () =
  let json =
    show_json_resources
      {|{"address":"aws_db_instance.postgres","type":"aws_db_instance","values":{"identifier":"pluto-postgres","arn":"arn:aws:rds:eu-west-1:111122223333:db:pluto-postgres","skip_final_snapshot":true}}|}
  in
  match inventory_of_show_json json with
  | State_represented [ resource ] ->
    Alcotest.(check (option string))
      "the identifier is kept"
      (Some "pluto-postgres")
      resource.identifier;
    Alcotest.(check (option bool))
      "retention state is kept"
      (Some true)
      resource.skip_final_snapshot
  | _ -> Alcotest.fail "expected a represented resource"
;;

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
  ; mutable reports : string list
  ; mutable order : string list
  }

let verified_observation =
  { Sol_cli_destroy_verification.state = State_absent
  ; sweep = Sweep_ran { residues = []; indeterminate = [] }
  ; retention = Retention_not_required "this fixture declares no retention"
  }
;;

let fake_deps
      ?(state = Ok {|{}|})
      ?(outputs = Outputs_available)
      ?(prepare = fun ~state:_ -> Sol_cli_cloud_lifecycle.Nothing_to_prepare)
      ?(reconcile = fun () -> Ok ())
      ?(platform = fun () -> Ok ())
      ?(remove = fun () -> Ok ())
      ?(release_workloads = fun () -> Ok ())
      ?(destroy_substrate = fun () -> Ok ())
      ?(verify_destruction = fun ~pre_destroy:_ ~preparation:_ -> verified_observation)
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
    ; reports = []
    ; order = []
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
    ; release_workloads =
        (fun () ->
          calls.order <- "release" :: calls.order;
          release_workloads ())
    ; destroy_substrate =
        (fun () ->
          calls.substrate <- calls.substrate + 1;
          calls.order <- "substrate" :: calls.order;
          destroy_substrate ())
    ; verify_destruction =
        (fun ~pre_destroy ~preparation ->
          calls.verify <- calls.verify + 1;
          verify_destruction ~pre_destroy ~preparation)
    ; report = (fun message -> calls.reports <- message :: calls.reports)
    ; warn = (fun _ -> ())
    }
  in
  deps, calls
;;

let test_empty_state_destroys_without_outputs () =
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
  Alcotest.(check int)
    "a degraded success exits 0 with a warning"
    exit_clean
    (exit_code outcome)
;;

let test_platform_failure_is_not_a_degradation () =
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
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~reconcile:(fun () -> Error "no authority")
      ~remove:(fun () -> Error "cleanup refused")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations; cleanup = Cleanup_failed cleanup_message; _ } ->
     Alcotest.(check string)
       "the removal failure is carried as cleanup evidence"
       "cleanup refused"
       cleanup_message;
     Alcotest.(check bool)
       "and as a degradation naming what it removed"
       true
       (List.exists
          (fun m ->
             contains (Str.regexp_string "elevated access") m
             && contains (Str.regexp_string "cleanup refused") m)
          degradations);
     Alcotest.(check bool)
       "and the skipped teardown is still there"
       true
       (List.exists
          (fun m -> contains (Str.regexp_string "bootstrap authority") m)
          degradations)
   | _ ->
     Alcotest.fail
       "a cleanup failure the substrate deletes anyway must proceed, with every fact \
        preserved");
  Alcotest.(check int) "the substrate was destroyed" 1 calls.substrate;
  Alcotest.(check int) "and absence was still verified" 1 calls.verify;
  Alcotest.(check int) "so a verified absence exits 0" exit_clean (exit_code outcome)
;;

let test_cleanup_failure_does_not_decide_absence () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~remove:(fun () -> Error "terraform exited 1: access removal failed")
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ ->
        { Sol_cli_destroy_verification.state = State_absent
        ; sweep =
            Sweep_ran
              { residues =
                  [ "the cluster is still listed by the provider, in state ERROR" ]
              ; indeterminate = []
              }
        ; retention = Retention_not_required "this fixture declares no retention"
        })
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_failed { failure = Verification_failed message; cleanup; degradations; _ } ->
     Alcotest.(check bool)
       "the absence check is what failed, not the cleanup"
       true
       (contains (Str.regexp_string "still listed by the provider") message);
     Alcotest.(check bool)
       "the cleanup failure is preserved as evidence"
       true
       (match cleanup with
        | Cleanup_failed _ -> true
        | _ -> false);
     Alcotest.(check bool)
       "and as a degradation"
       true
       (List.exists
          (fun m -> contains (Str.regexp_string "access removal failed") m)
          degradations)
   | _ -> Alcotest.fail "residue must fail the destroy however the cleanup went");
  Alcotest.(check int) "a destroy with residue exits 1" exit_failure (exit_code outcome);
  Alcotest.(check bool)
    "and claims no absence"
    false
    (contains (Str.regexp_string "reached verified absence") (completion_message outcome))
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

let continue_failure reason =
  Sol_cli_cloud_lifecycle.Preparation_failed
    { reason; policy = Sol_cli_cloud_lifecycle.Continue_to_destroy }
;;

let block_failure reason =
  Sol_cli_cloud_lifecycle.Preparation_failed
    { reason; policy = Sol_cli_cloud_lifecycle.Block_destroy }
;;

let test_continue_preparation_failure_destroys () =
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
    "a degraded preparation with verified absence exits 0"
    exit_clean
    (exit_code outcome)
;;

let test_unremovable_elevated_access_does_not_immobilise_the_substrate () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        continue_failure "the deletion guards could not be lowered: replace refused")
      ~remove:(fun () -> Error "the binding could not be removed: replace refused")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { cleanup = Cleanup_failed message; degradations; _ } ->
     Alcotest.(check string)
       "the unremoved binding stays visible as evidence"
       "the binding could not be removed: replace refused"
       message;
     Alcotest.(check bool)
       "and the run records it as a degradation"
       true
       (List.length degradations >= 1)
   | _ ->
     Alcotest.fail
       "a cleanup failure must not make the substrate immortal: the binding it removes \
        lives inside the cluster");
  Alcotest.(check int) "the substrate was destroyed anyway" 1 calls.substrate;
  Alcotest.(check int) "and the absence check still ran" 1 calls.verify;
  Alcotest.(check int) "a verified absence exits 0" exit_clean (exit_code outcome)
;;

let test_the_workload_scope_comes_from_the_labelled_pods () =
  let listing =
    {|{"items":[{"metadata":{"namespace":"pluto-payments","labels":{"workspace":"pluto"}}},
                {"metadata":{"namespace":"pluto-comms","labels":{"workspace":"pluto"}}},
                {"metadata":{"namespace":"pluto-payments","labels":{"workspace":"pluto"}}},
                {"metadata":{"namespace":"other"}}]}|}
  in
  Alcotest.(check (result (list string) string))
    "distinct namespaces, in a stable order"
    (Ok [ "other"; "pluto-comms"; "pluto-payments" ])
    (Sol_cli_workload_scope.namespaces_of_pods_json listing);
  Alcotest.(check (result (list string) string))
    "a listing with no pods is an empty scope, not an error"
    (Ok [])
    (Sol_cli_workload_scope.namespaces_of_pods_json {|{"items":[]}|});
  Alcotest.(check bool)
    "a listing that cannot be read is an error rather than an empty scope"
    true
    (match Sol_cli_workload_scope.namespaces_of_pods_json "not json" with
     | Error _ -> true
     | Ok _ -> false)
;;

let test_the_removal_waits_for_the_pods_to_go () =
  let args =
    Sol_cli_workload_scope.delete_namespace_args
      ~namespace:"pluto-payments"
      ~timeout_seconds:300
  in
  Alcotest.(check bool)
    "the removal is a wait, so the sessions are closed before the database is touched"
    true
    (List.exists (fun arg -> arg = "--wait=true") args);
  Alcotest.(check bool)
    "and it is bounded"
    true
    (List.exists (fun arg -> Sol_cli_string.contains ~needle:"--timeout=" arg) args);
  Alcotest.(check string)
    "the listing asks for the workspace's pods across every namespace"
    "workspace=pluto"
    (Sol_cli_workload_scope.selector ~workspace:"pluto")
;;

let test_the_workloads_are_released_before_the_substrate_is_destroyed () =
  let deps, calls = fake_deps () in
  ignore (execute ~deps);
  Alcotest.(check (list string))
    "the workloads that hold the managed database's sessions are released first"
    [ "release"; "substrate" ]
    (List.rev calls.order)
;;

let test_a_release_failure_is_reported_and_the_teardown_continues () =
  let deps, calls =
    fake_deps ~release_workloads:(fun () -> Error "the cluster refused the request") ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Sol_cli_cloud_destroy.Destroy_succeeded { degradations; _ } ->
     Alcotest.(check bool)
       "the failure is named as a degradation rather than swallowed"
       true
       (List.exists
          (fun degradation ->
             Sol_cli_string.contains ~needle:"could not be released" degradation)
          degradations)
   | _ -> Alcotest.fail "a release failure must not stop the teardown");
  Alcotest.(check int) "and the substrate is still destroyed" 1 calls.substrate
;;

let test_destroy_that_cannot_converge_claims_no_absence () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        continue_failure "the deletion guards could not be lowered: replace refused")
      ~remove:(fun () -> Error "the binding could not be removed: replace refused")
      ~destroy_substrate:(fun () ->
        Error
          "Error waiting for deleting GKE cluster: the cluster is in ERROR and Terraform \
           refused the plan")
      ()
  in
  let outcome = execute ~deps in
  Alcotest.(check int)
    "a destroy that cannot converge exits non-zero"
    exit_failure
    (exit_code outcome);
  Alcotest.(check int) "the substrate destroy was attempted" 1 calls.substrate;
  let message = completion_message outcome in
  Alcotest.(check bool)
    "and it never claims absence"
    false
    (contains (Str.regexp_string "reached verified absence") message);
  Alcotest.(check bool)
    "it says the destruction did not converge"
    true
    (contains (Str.regexp_string "did not converge") message)
;;

let test_residue_the_state_does_not_own_is_not_absence () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ ->
        { Sol_cli_destroy_verification.state = State_absent
        ; sweep =
            Sweep_ran
              { residues =
                  [ "the cluster is still listed by the provider, in state ERROR" ]
              ; indeterminate = []
              }
        ; retention = Retention_not_required "this fixture declares no retention"
        })
      ()
  in
  let outcome = execute ~deps in
  Alcotest.(check int)
    "residue outside Terraform's state still fails"
    exit_failure
    (exit_code outcome);
  Alcotest.(check int) "the sweep ran after the destroy" 1 calls.verify;
  let message = completion_message outcome in
  Alcotest.(check bool)
    "and the run claims no absence"
    false
    (contains (Str.regexp_string "reached verified absence") message)
;;

let test_inconclusive_residue_probe_is_unknown () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ ->
        { Sol_cli_destroy_verification.state = State_absent
        ; sweep =
            Sweep_ran
              { residues = []
              ; indeterminate =
                  [ "the GCP residue check could not establish the target's project, so \
                     the service-networking peering check was not run"
                  ]
              }
        ; retention = Retention_not_required "this fixture declares no retention"
        })
      ()
  in
  let outcome = execute ~deps in
  let message = completion_message outcome in
  (match outcome with
   | Destroy_succeeded _ ->
     Alcotest.(check bool)
       "the summary never claims verified absence while a probe did not run"
       false
       (contains (Str.regexp_string "reached verified absence") message);
     Alcotest.(check bool)
       "it says so plainly instead"
       true
       (contains (Str.regexp_string "residue absence is NOT established") message
        && contains (Str.regexp_string "peering check was not run") message)
   | _ ->
     Alcotest.fail
       "a destroy whose owned resources are gone is not a failure; the observation is");
  Alcotest.(check int)
    "and the owned resources are still gone, so the destruction itself succeeded"
    exit_clean
    (exit_code outcome)
;;

let absence_rule = Sol_cli_absence.Named_for_target "the target's own cluster name"

let absent_class resource_class =
  Sol_cli_absence.Absent
    { resource_class
    ; identity = "qual-1"
    ; attribution = absence_rule
    ; checked_with = "gcloud list"
    }
;;

let present_class resource_class =
  Sol_cli_absence.Present
    { resource_class
    ; identity = "qual-1-postgres"
    ; found = [ "qual-1-postgres" ]
    ; attribution = absence_rule
    ; checked_with = "gcloud list"
    }
;;

let unobservable_class resource_class =
  Sol_cli_absence.Unobservable
    { resource_class; reason = "the CLI is unavailable"; checked_with = "gcloud list" }
;;

let test_an_empty_inventory_permits_the_absence_claim () =
  let observations = [ absent_class "GKE cluster"; absent_class "Cloud SQL instance" ] in
  Alcotest.(check bool)
    "every class observed absent permits the claim"
    true
    (Sol_cli_absence.permits_absence_claim (Sol_cli_absence.verdict observations));
  Alcotest.(check bool)
    "and the sweep carries no residue and no unknown"
    true
    (Sol_cli_absence.to_sweep observations
     = Sol_cli_destroy_verification.Sweep_ran { residues = []; indeterminate = [] })
;;

let test_a_present_resource_refuses_the_absence_claim () =
  let observations = [ absent_class "GKE cluster"; present_class "Cloud SQL instance" ] in
  let verdict = Sol_cli_absence.verdict observations in
  Alcotest.(check bool)
    "a resource the state never adopted still refuses the claim"
    false
    (Sol_cli_absence.permits_absence_claim verdict);
  Alcotest.(check bool)
    "and it is named"
    true
    (List.exists
       (fun line -> contains (Str.regexp_string "qual-1-postgres") line)
       (Sol_cli_absence.residue verdict));
  let verification =
    Sol_cli_destroy_verification.classify
      { Sol_cli_destroy_verification.state = State_absent
      ; sweep = Sol_cli_absence.to_sweep observations
      ; retention = Retention_not_required "fixture"
      }
  in
  Alcotest.(check bool)
    "so the destruction verdict is not verified"
    false
    (Sol_cli_destroy_verification.is_verified verification)
;;

let test_an_unobservable_class_refuses_the_absence_claim () =
  let verdict =
    Sol_cli_absence.verdict
      [ absent_class "GKE cluster"; unobservable_class "forwarding rule" ]
  in
  Alcotest.(check bool)
    "an observation that did not run is UNKNOWN, never absence"
    false
    (Sol_cli_absence.permits_absence_claim verdict)
;;

let test_a_present_resource_outranks_an_unobservable_class () =
  let verdict =
    Sol_cli_absence.verdict
      [ unobservable_class "GKE cluster"; present_class "Cloud SQL instance" ]
  in
  Alcotest.(check bool)
    "both refuse the claim"
    false
    (Sol_cli_absence.permits_absence_claim verdict);
  Alcotest.(check bool)
    "and the resource that was actually found is reported first"
    true
    (match Sol_cli_absence.residue verdict with
     | first :: _ -> contains (Str.regexp_string "qual-1-postgres") first
     | [] -> false)
;;

let test_an_external_resource_is_not_residue () =
  let observations =
    [ Sol_cli_absence.External
        { resource_class = "Terraform state bucket"
        ; identity = "the durable backend"
        ; reason = "durable by contract"
        }
    ; absent_class "GKE cluster"
    ]
  in
  Alcotest.(check bool)
    "a resource the contract keeps alive is not this target's residue"
    true
    (Sol_cli_absence.permits_absence_claim (Sol_cli_absence.verdict observations))
;;

let test_the_report_explains_attribution () =
  let report = Sol_cli_absence.report [ present_class "Cloud SQL instance" ] in
  Alcotest.(check bool)
    "it says what was found"
    true
    (contains (Str.regexp_string "PRESENT: Cloud SQL instance") report);
  Alcotest.(check bool)
    "and why it is this target's"
    true
    (contains (Str.regexp_string "the target's own cluster name") report);
  Alcotest.(check bool)
    "and which command established it"
    true
    (contains (Str.regexp_string "gcloud list") report)
;;

let recovery_entry address ~resource_class ~observed_as ~ownership ~import_identity =
  Sol_cli_resource_identity.
    { address
    ; resource_class
    ; observed_as
    ; ownership
    ; identity = "fixture"
    ; import_identity
    }
;;

let recovery_present resource_class found =
  Sol_cli_absence.Present
    { resource_class
    ; identity = "fixture"
    ; found = [ found ]
    ; attribution = absence_rule
    ; checked_with = "gcloud list"
    }
;;

let recovery_plan ?(state_addresses = []) ~entries observations =
  Sol_cli_ownership_reconciliation.dispositions ~entries ~state_addresses observations
;;

let recovery_unobservable resource_class reason =
  Sol_cli_absence.Unobservable { resource_class; reason; checked_with = "gcloud list" }
;;

let recovery_absent resource_class =
  Sol_cli_absence.Absent
    { resource_class
    ; identity = "fixture"
    ; attribution = absence_rule
    ; checked_with = "gcloud list"
    }
;;

let mentions haystack needle = Sol_cli_string.contains ~needle haystack

let test_recovery_carries_a_check_that_could_not_run () =
  let dispositions =
    recovery_plan ~entries:[] [ recovery_unobservable "Cloud NAT" "AccessDenied: denied" ]
  in
  (match dispositions with
   | [ Sol_cli_ownership_reconciliation.Unresolved { resource_class; reason } ] ->
     Alcotest.(check string) "the class is named" "Cloud NAT" resource_class;
     Alcotest.(check string) "and the provider's reason" "AccessDenied: denied" reason
   | _ -> Alcotest.fail "a check that could not run must be carried, never dropped");
  Alcotest.(check int)
    "it is outstanding, so the command exits nonzero"
    1
    (List.length (Sol_cli_ownership_reconciliation.unreconciled dispositions));
  let outcome = Sol_cli_ownership_reconciliation.outcome dispositions in
  Alcotest.(check bool)
    "no reconciled claim is made"
    false
    (mentions outcome "reconciled. No changes.");
  Alcotest.(check bool)
    "the unresolved check is reported"
    true
    (mentions outcome "Cloud NAT could not be checked");
  Alcotest.(check bool)
    "and absence is not claimed for it"
    true
    (mentions outcome "nothing is claimed about the resources those checks cover")
;;

let test_recovery_reports_present_and_unresolved_together () =
  let entries =
    [ recovery_entry
        "google_sql_database_instance.postgres"
        ~resource_class:"Cloud SQL instance"
        ~observed_as:"qual-1-postgres"
        ~ownership:Sol_cli_resource_identity.Direct
        ~import_identity:"qual-1-postgres"
    ]
  in
  let dispositions =
    recovery_plan
      ~entries
      [ recovery_present "Cloud SQL instance" "qual-1-postgres"
      ; recovery_unobservable "Cloud NAT" "AccessDenied: denied"
      ]
  in
  let outcome = Sol_cli_ownership_reconciliation.outcome dispositions in
  Alcotest.(check bool)
    "the recoverable resource is still reported"
    true
    (mentions outcome "Restored Terraform ownership");
  Alcotest.(check bool)
    "the unresolved check is reported too"
    true
    (mentions outcome "Cloud NAT could not be checked");
  Alcotest.(check bool)
    "and the result is not called reconciled"
    false
    (mentions outcome "Infrastructure ownership is reconciled.")
;;

let test_recovery_claims_no_changes_only_for_a_complete_inventory () =
  let dispositions = recovery_plan ~entries:[] [ recovery_absent "Cloud NAT" ] in
  Alcotest.(check int)
    "nothing is outstanding"
    0
    (List.length (Sol_cli_ownership_reconciliation.unreconciled dispositions));
  Alcotest.(check string)
    "a complete all-absent inventory reconciles"
    "Infrastructure ownership is reconciled.\nNo changes.\n"
    (Sol_cli_ownership_reconciliation.outcome dispositions)
;;

let test_recovery_maps_a_present_resource_to_its_address () =
  let entries =
    [ recovery_entry
        "google_sql_database_instance.postgres"
        ~resource_class:"Cloud SQL instance"
        ~observed_as:"qual-1-postgres"
        ~ownership:Sol_cli_resource_identity.Direct
        ~import_identity:"qual-1-postgres"
    ]
  in
  let dispositions =
    recovery_plan ~entries [ recovery_present "Cloud SQL instance" "qual-1-postgres" ]
  in
  match dispositions with
  | [ Sol_cli_ownership_reconciliation.Recover candidate ] ->
    Alcotest.(check string)
      "the address comes from the registry"
      "google_sql_database_instance.postgres"
      candidate.address;
    Alcotest.(check string)
      "and the import identity is the provider name"
      "qual-1-postgres"
      candidate.import_identity
  | _ -> Alcotest.fail "a mappable orphan must be a recovery candidate"
;;

let test_recovery_refuses_a_resource_the_state_already_owns () =
  let entries =
    [ recovery_entry
        "google_sql_database_instance.postgres"
        ~resource_class:"Cloud SQL instance"
        ~observed_as:"qual-1-postgres"
        ~ownership:Sol_cli_resource_identity.Direct
        ~import_identity:"qual-1-postgres"
    ]
  in
  let dispositions =
    recovery_plan
      ~state_addresses:[ "google_sql_database_instance.postgres" ]
      ~entries
      [ recovery_present "Cloud SQL instance" "qual-1-postgres" ]
  in
  match dispositions with
  | [ Sol_cli_ownership_reconciliation.Already_owned _ ] -> ()
  | _ -> Alcotest.fail "a resource the state already owns must not be imported twice"
;;

let test_recovery_refuses_a_class_it_cannot_map () =
  let dispositions =
    recovery_plan ~entries:[] [ recovery_present "forwarding rule" "k8s2-something" ]
  in
  match dispositions with
  | [ Sol_cli_ownership_reconciliation.Unmapped { resource_class; found } ] ->
    Alcotest.(check string)
      "a controller-created class is reported, not adopted"
      "forwarding rule"
      resource_class;
    Alcotest.(check string) "and named" "k8s2-something" found
  | _ -> Alcotest.fail "a class with no Terraform address must be reported, never adopted"
;;

let test_recovery_refuses_an_unmapped_class () =
  let dispositions =
    recovery_plan ~entries:[] [ recovery_present "Some future class" "whatever" ]
  in
  match dispositions with
  | [ Sol_cli_ownership_reconciliation.Unmapped _ ] -> ()
  | _ -> Alcotest.fail "a class with no registry entry must be reported, never guessed at"
;;

let test_recovery_refuses_a_class_the_registry_calls_unrecoverable () =
  let entries =
    [ recovery_entry
        "google_service_networking_connection.sql"
        ~resource_class:"service-networking peering connection"
        ~observed_as:"qual-1"
        ~ownership:
          (Sol_cli_resource_identity.Direct_not_recoverable
             "a composite import identity Sol has not established")
        ~import_identity:""
    ]
  in
  let dispositions =
    recovery_plan
      ~entries
      [ recovery_present "service-networking peering connection" "qual-1" ]
  in
  match dispositions with
  | [ Sol_cli_ownership_reconciliation.Cannot_recover { reason; _ } ] ->
    Alcotest.(check bool)
      "the reason is the registry's, not a guess"
      true
      (contains (Str.regexp_string "composite import identity") reason)
  | _ -> Alcotest.fail "a class marked unrecoverable must be refused with its reason"
;;

let test_recovery_refuses_an_ambiguous_match () =
  let entries =
    [ recovery_entry
        "provider.one"
        ~resource_class:"Cloud SQL instance"
        ~observed_as:"qual-1-postgres"
        ~ownership:Sol_cli_resource_identity.Direct
        ~import_identity:"qual-1-postgres"
    ; recovery_entry
        "provider.two"
        ~resource_class:"Cloud SQL instance"
        ~observed_as:"qual-1"
        ~ownership:Sol_cli_resource_identity.Direct
        ~import_identity:"qual-1-postgres"
    ]
  in
  let dispositions =
    recovery_plan ~entries [ recovery_present "Cloud SQL instance" "qual-1-postgres" ]
  in
  match dispositions with
  | [ Sol_cli_ownership_reconciliation.Cannot_recover { reason; _ } ] ->
    Alcotest.(check bool)
      "two candidate addresses are reported as ambiguous"
      true
      (contains (Str.regexp_string "ambiguous") reason)
  | _ -> Alcotest.fail "an ambiguous mapping must be refused, never resolved"
;;

let test_reconciliation_outcome_reports_what_it_restored () =
  let restored =
    Sol_cli_ownership_reconciliation.Recover
      { address = "google_sql_database_instance.postgres"
      ; resource_class = "Cloud SQL instance"
      ; found = "qual-1-postgres"
      ; import_identity = "qual-1-postgres"
      }
  in
  let text = Sol_cli_ownership_reconciliation.outcome [ restored ] in
  List.iter
    (fun expected ->
       Alcotest.(check bool) expected true (contains (Str.regexp_string expected) text))
    [ "Found Cloud SQL instance qual-1-postgres."
    ; "Restored Terraform ownership:"
    ; "  google_sql_database_instance.postgres"
    ; "Infrastructure ownership is reconciled."
    ]
;;

let test_reconciliation_outcome_says_no_changes () =
  let text = Sol_cli_ownership_reconciliation.outcome [] in
  Alcotest.(check bool)
    "a reconciled target reports no changes"
    true
    (contains (Str.regexp_string "No changes.") text)
;;

let test_reconciliation_outcome_refuses_rather_than_claiming () =
  let refused =
    Sol_cli_ownership_reconciliation.Cannot_recover
      { resource_class = "service-networking peering connection"
      ; found = "qual-1"
      ; reason = "a composite import identity Sol has not established"
      }
  in
  let text = Sol_cli_ownership_reconciliation.outcome [ refused ] in
  Alcotest.(check bool)
    "an unreconcilable resource is named, with its reason"
    true
    (contains (Str.regexp_string "is not reconciled") text);
  Alcotest.(check bool)
    "and the reason is the registry's"
    true
    (contains (Str.regexp_string "composite import identity") text)
;;

let test_reconciliation_outcome_does_not_claim_a_dry_run_changed_anything () =
  let candidate =
    Sol_cli_ownership_reconciliation.Recover
      { address = "google_sql_database_instance.postgres"
      ; resource_class = "Cloud SQL instance"
      ; found = "qual-1-postgres"
      ; import_identity = "qual-1-postgres"
      }
  in
  let text = Sol_cli_ownership_reconciliation.outcome ~dry_run:true [ candidate ] in
  Alcotest.(check bool)
    "a dry run says what it would do, not what it did"
    true
    (contains (Str.regexp_string "Would restore Terraform ownership:") text);
  Alcotest.(check bool)
    "and never claims the work happened"
    false
    (contains (Str.regexp_string "Infrastructure ownership is reconciled.") text)
;;

let test_block_preparation_failure_blocks_destruction () =
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
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        Sol_cli_cloud_lifecycle.Prepared (Prepared { retained = None }))
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded
       { preparation = Prepared { retained = None }; degradations = []; _ } -> ()
   | _ -> Alcotest.fail "a clean preparation and a clean destroy must be a clean success");
  Alcotest.(check int) "the substrate was destroyed" 1 calls.substrate;
  Alcotest.(check int) "clean success exits 0" exit_clean (exit_code outcome)
;;

let test_degradation_preserved_when_destroy_fails () =
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

let test_refused_removal_does_not_stop_the_substrate_destroy () =
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
   | Destroy_succeeded { cleanup = Cleanup_failed _; degradations; _ } ->
     Alcotest.(check bool)
       "the refused removal is still not reported as a successful cleanup"
       true
       (List.exists
          (fun m -> contains (Str.regexp_string "elevated access") m)
          degradations)
   | _ -> Alcotest.fail "the refused removal must stay visible as a degradation");
  Alcotest.(check int)
    "and it does not immobilise the substrate: the destroy still ran"
    1
    calls.substrate
;;

let observation_with
      ?(state = Sol_cli_destroy_verification.State_absent)
      ?(sweep =
        Sol_cli_destroy_verification.Sweep_ran { residues = []; indeterminate = [] })
      ?(retention = Sol_cli_destroy_verification.Retention_not_required "fixture")
      ()
  =
  { Sol_cli_destroy_verification.state; sweep; retention }
;;

let test_degradation_with_verified_absence () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ -> continue_failure "guards not lowered")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations = [ _ ]; verification; _ } ->
     Alcotest.(check bool)
       "the observation is carried, and it is the verified one"
       true
       (verification = verified_observation)
   | _ ->
     Alcotest.fail "a degraded preparation with verified absence is a degraded success");
  Alcotest.(check int)
    "a degraded success exits 0 with a warning"
    exit_clean
    (exit_code outcome);
  Alcotest.(check int) "the substrate destroy ran" 1 calls.substrate
;;

let test_verification_unknown_is_a_failure () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ ->
        observation_with
          ~state:(Sol_cli_destroy_verification.State_unreadable "permission denied")
          ())
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_failed
       { failure = Verification_failed message
       ; degradations = []
       ; verification = Some _
       ; _
       } ->
     Alcotest.(check bool)
       "the failure says the postcondition was not established"
       true
       (contains (Str.regexp_string "could not be established") message)
   | _ -> Alcotest.fail "an UNKNOWN observation must fail the destroy");
  Alcotest.(check int)
    "UNKNOWN is failure, not degraded success"
    exit_failure
    (exit_code outcome);
  Alcotest.(check int) "the destroy itself was still attempted" 1 calls.substrate
;;

let test_degradation_preserved_when_verification_fails () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ -> continue_failure "guards not lowered")
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ ->
        observation_with
          ~sweep:
            (Sol_cli_destroy_verification.Sweep_ran
               { residues = [ "a load balancer remains" ]; indeterminate = [] })
          ~retention:(Retention_not_required "fixture")
          ())
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_failed
       { failure = Verification_failed message
       ; degradations = [ degraded ]
       ; verification = Some _
       ; _
       } ->
     Alcotest.(check string)
       "the preparation degradation is preserved"
       "preparation: guards not lowered"
       degraded;
     Alcotest.(check bool)
       "and the violation is what failed the run"
       true
       (contains (Str.regexp_string "violated") message)
   | _ -> Alcotest.fail "a violation must fail the destroy and keep the degradation");
  Alcotest.(check int) "a violation exits 1" exit_failure (exit_code outcome)
;;

let test_missing_retention_fails () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ ->
        observation_with
          ~retention:
            (Retention_violated
               "final-snapshot NOT observed (destroy_retention = final-snapshot): the \
                target declared it keeps its final snapshot, and the provider explicitly \
                reports that snap-1 does not exist")
          ())
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_failed { failure = Verification_failed message; degradations = []; _ } ->
     Alcotest.(check bool)
       "the promised snapshot is named"
       true
       (contains (Str.regexp_string "snap-1") message)
   | _ -> Alcotest.fail "a missing promised snapshot must fail the destroy");
  Alcotest.(check int) "it exits 1" exit_failure (exit_code outcome)
;;

let test_fully_clean_is_exit_0 () =
  let observed =
    observation_with
      ~retention:
        (Retention_required_and_observed
           "final snapshot snap-1 observed available (destroy_retention = final-snapshot)")
      ()
  in
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        Sol_cli_cloud_lifecycle.Prepared (Prepared { retained = None }))
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ -> observed)
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations = []; verification; _ } ->
     Alcotest.(check bool) "the evidence is carried" true (verification = observed)
   | _ -> Alcotest.fail "a fully clean destroy must be a clean success");
  Alcotest.(check int) "clean success exits 0" exit_clean (exit_code outcome);
  Alcotest.(check int) "the verification ran" 1 calls.verify
;;

let test_blocked_destroy_never_verifies () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        Sol_cli_cloud_lifecycle.Preparation_failed
          { reason = "the target's retention guarantee could not be established"
          ; policy = Sol_cli_cloud_lifecycle.Block_destroy
          })
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_blocked _ -> ()
   | _ -> Alcotest.fail "a Block_destroy preparation must block");
  Alcotest.(check int) "verification never ran" 0 calls.verify;
  Alcotest.(check int) "the substrate destroy never ran" 0 calls.substrate
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
        ; Alcotest.test_case "identifier is captured" `Quick test_identifier_captured
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
            "cleanup failure does not decide absence"
            `Quick
            test_cleanup_failure_does_not_decide_absence
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
            "an unremovable elevated binding does not immobilise the substrate"
            `Quick
            test_unremovable_elevated_access_does_not_immobilise_the_substrate
        ; Alcotest.test_case
            "a destroy that cannot converge claims no absence (FND-0069)"
            `Quick
            test_destroy_that_cannot_converge_claims_no_absence
        ; Alcotest.test_case
            "residue the state does not own is not absence"
            `Quick
            test_residue_the_state_does_not_own_is_not_absence
        ; Alcotest.test_case
            "an inconclusive residue probe is an unknown"
            `Quick
            test_inconclusive_residue_probe_is_unknown
        ; Alcotest.test_case
            "an empty provider inventory permits the claim"
            `Quick
            test_an_empty_inventory_permits_the_absence_claim
        ; Alcotest.test_case
            "a present resource refuses the claim (FND-0070)"
            `Quick
            test_a_present_resource_refuses_the_absence_claim
        ; Alcotest.test_case
            "an unobservable class refuses the claim"
            `Quick
            test_an_unobservable_class_refuses_the_absence_claim
        ; Alcotest.test_case
            "a present resource outranks an unobservable class"
            `Quick
            test_a_present_resource_outranks_an_unobservable_class
        ; Alcotest.test_case
            "an external resource is not residue"
            `Quick
            test_an_external_resource_is_not_residue
        ; Alcotest.test_case
            "the report explains attribution"
            `Quick
            test_the_report_explains_attribution
        ; Alcotest.test_case
            "recovery maps a present resource to its Terraform address (FND-0070)"
            `Quick
            test_recovery_maps_a_present_resource_to_its_address
        ; Alcotest.test_case
            "recovery carries a check that could not run (BUG-085)"
            `Quick
            test_recovery_carries_a_check_that_could_not_run
        ; Alcotest.test_case
            "recovery reports present and unresolved together (BUG-085)"
            `Quick
            test_recovery_reports_present_and_unresolved_together
        ; Alcotest.test_case
            "recovery claims no changes only for a complete inventory (BUG-085)"
            `Quick
            test_recovery_claims_no_changes_only_for_a_complete_inventory
        ; Alcotest.test_case
            "recovery does not import what the state already owns"
            `Quick
            test_recovery_refuses_a_resource_the_state_already_owns
        ; Alcotest.test_case
            "recovery reports a class it has no address for"
            `Quick
            test_recovery_refuses_a_class_it_cannot_map
        ; Alcotest.test_case
            "recovery refuses an unmapped class"
            `Quick
            test_recovery_refuses_an_unmapped_class
        ; Alcotest.test_case
            "recovery refuses a class the registry calls unrecoverable"
            `Quick
            test_recovery_refuses_a_class_the_registry_calls_unrecoverable
        ; Alcotest.test_case
            "reconciliation reports what it restored (FND-0070)"
            `Quick
            test_reconciliation_outcome_reports_what_it_restored
        ; Alcotest.test_case
            "reconciliation says no changes when there are none"
            `Quick
            test_reconciliation_outcome_says_no_changes
        ; Alcotest.test_case
            "reconciliation refuses rather than claiming"
            `Quick
            test_reconciliation_outcome_refuses_rather_than_claiming
        ; Alcotest.test_case
            "a dry run never claims to have changed anything"
            `Quick
            test_reconciliation_outcome_does_not_claim_a_dry_run_changed_anything
        ; Alcotest.test_case
            "recovery refuses an ambiguous mapping"
            `Quick
            test_recovery_refuses_an_ambiguous_match
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
            "a refused removal does not stop the substrate destroy"
            `Quick
            test_refused_removal_does_not_stop_the_substrate_destroy
        ] )
    ; ( "verification"
      , [ Alcotest.test_case
            "degradation + verified absence exits 0"
            `Quick
            test_degradation_with_verified_absence
        ; Alcotest.test_case
            "verification UNKNOWN exits 1"
            `Quick
            test_verification_unknown_is_a_failure
        ; Alcotest.test_case
            "degradation preserved when verification fails"
            `Quick
            test_degradation_preserved_when_verification_fails
        ; Alcotest.test_case
            "the workload scope comes from the labelled pods"
            `Quick
            test_the_workload_scope_comes_from_the_labelled_pods
        ; Alcotest.test_case
            "the removal waits for the pods to go"
            `Quick
            test_the_removal_waits_for_the_pods_to_go
        ; Alcotest.test_case
            "workloads are released before the substrate is destroyed"
            `Quick
            test_the_workloads_are_released_before_the_substrate_is_destroyed
        ; Alcotest.test_case
            "a release failure is reported and teardown continues"
            `Quick
            test_a_release_failure_is_reported_and_the_teardown_continues
        ; Alcotest.test_case "missing retention fails" `Quick test_missing_retention_fails
        ; Alcotest.test_case "fully clean exits 0" `Quick test_fully_clean_is_exit_0
        ; Alcotest.test_case
            "blocked destroy never verifies"
            `Quick
            test_blocked_destroy_never_verifies
        ] )
    ]
;;
