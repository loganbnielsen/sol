(* Offline tests for destruction verification, as narrowed by DEC-045 / REFAC-094.

   For resources Terraform is configured to delete, a successful destroy plus an
   empty state is the authority, so what is verified here is what Terraform cannot
   speak for: the post-destroy state itself, residue Terraform does not own, and
   retention. The epistemic rule is unchanged: failure to obtain evidence is not
   evidence of the postcondition, and UNKNOWN never becomes absence.

   Every provider call is injected, so none of this needs terraform, gcloud, aws or
   a network. *)

open Sol_cli_destroy_verification

(* REFAC-097: the provider-evidence classifiers live with their providers. *)
let gcp_absence_message = Sol_cli_gcp_destruction.gcp_absence_message
let classify_final_snapshot = Sol_cli_aws_destruction.classify_final_snapshot
let classify_instance_snapshots = Sol_cli_aws_destruction.classify_instance_snapshots
let contains needle haystack = Sol_cli_string.contains ~needle haystack
let answered ?(stdout = "") status stderr = Answered { status; stdout; stderr }

let observation
      ?(state = State_absent)
      ?(sweep = Sweep_ran { residues = []; indeterminate = [] })
      ?(retention = Retention_not_required "this fixture declares no retention")
      ()
  =
  { state; sweep; retention }
;;

(* ── The Terraform-state postcondition ─────────────────────────────────────── *)

(* Case 7: an empty read is state-absence evidence. *)
let test_state_empty () =
  Alcotest.(check bool)
    "an empty read is absent"
    true
    (state_evidence (Ok []) = State_absent)
;;

(* Case 8: a state that still represents the target is a verification failure. *)
let test_state_residue () =
  let state = state_evidence (Ok [ "google_container_cluster.main" ]) in
  Alcotest.(check bool)
    "a represented address is residue"
    true
    (match state with
     | State_residue [ "google_container_cluster.main" ] -> true
     | _ -> false);
  let verdict = classify (observation ~state ()) in
  Alcotest.(check int) "it is a violation" 1 (List.length verdict.violations);
  Alcotest.(check bool)
    "and it names the address that remains"
    true
    (contains "google_container_cluster.main" (List.hd verdict.violations))
;;

(* Case 9: a state that could not be read is UNKNOWN, not absence. *)
let test_state_unreadable () =
  let verdict =
    classify (observation ~state:(state_evidence (Error "terraform show exited 1")) ())
  in
  Alcotest.(check (list string)) "no absence is inferred" [] verdict.violations;
  Alcotest.(check int) "it is an unknown" 1 (List.length verdict.unknowns);
  Alcotest.(check bool) "not verified" false (is_verified verdict)
;;

(* ── Combining the evidence ────────────────────────────────────────────────── *)

(* Empty state, no residue, retention settled: the postcondition is established. *)
let test_combined_verified () =
  let verdict = classify (observation ()) in
  Alcotest.(check bool) "verified" true (is_verified verdict);
  Alcotest.(check string)
    "and says so"
    "the destruction postcondition is established"
    (verdict_message verdict)
;;

(* Residue Terraform does not own is a violation; an inconclusive check is reported
   but is not itself a violation, and does not verify anything either. *)
let test_sweep () =
  let verdict =
    classify
      (observation
         ~sweep:
           (Sweep_ran { residues = [ "AWS EBS volumes remain" ]; indeterminate = [] })
         ())
  in
  Alcotest.(check int) "a residue is a violation" 1 (List.length verdict.violations);
  let verdict =
    classify
      (observation
         ~sweep:
           (Sweep_ran
              { residues = []; indeterminate = [ "the peering could not be checked" ] })
         ())
  in
  Alcotest.(check (list string))
    "an inconclusive check is not a violation"
    []
    verdict.violations;
  Alcotest.(check bool)
    "and does not by itself block an otherwise-verified result"
    true
    (is_verified verdict);
  Alcotest.(check bool)
    "a residue with an empty state still fails: the empty state speaks only for what \
     Terraform manages"
    false
    (is_verified
       (classify
          (observation
             ~state:State_absent
             ~sweep:
               (Sweep_ran { residues = [ "a load balancer remains" ]; indeterminate = [] })
             ())))
;;

(* The GCP not-found subject rule, still used by the peering check: a 404 about
   another project is not absence (finding C). *)
let test_gcp_not_found_subject_must_match () =
  Alcotest.(check bool)
    "a not-found naming our project is absence"
    true
    (gcp_absence_message
       ~project:"captured-project"
       "ERROR: code=404 Not found: projects/captured-project/x");
  Alcotest.(check bool)
    "a not-found naming another project is not"
    false
    (gcp_absence_message
       ~project:"captured-project"
       "ERROR: code=404 Not found: projects/other-project/x");
  Alcotest.(check bool)
    "a not-found naming no project has no subject to contradict"
    true
    (gcp_absence_message
       ~project:"captured-project"
       "ERROR: NOT_FOUND: Resource was not found");
  Alcotest.(check bool)
    "a permission error is not absence"
    false
    (gcp_absence_message ~project:"captured-project" "ERROR: PERMISSION_DENIED")
;;

(* ── Retention, observed ───────────────────────────────────────────────────── *)

let final_snapshot stdout = answered ~stdout 0 ""
let declared = Sol_cli_cloud_lifecycle.Retain_final_snapshot

(* Case 17: the promised snapshot exists and is available. *)
let test_retention_final_snapshot_observed () =
  match
    classify_final_snapshot
      ~declared
      ~snapshot_id:"snap-1"
      (final_snapshot
         {|{"DBSnapshots":[{"DBSnapshotIdentifier":"snap-1","SnapshotType":"manual","Status":"available"}]}|})
  with
  | Sol_cli_aws_destruction.Settled (Retention_required_and_observed evidence) ->
    Alcotest.(check bool)
      "the observation names the identifier and the state"
      true
      (contains "snap-1" evidence && contains "available" evidence)
  | Sol_cli_aws_destruction.Settled _ ->
    Alcotest.fail "an available snapshot is a met retention guarantee"
  | Sol_cli_aws_destruction.Pending message ->
    Alcotest.failf "an available snapshot is not pending: %s" message
;;

(* Case 18: the snapshot explicitly does not exist. *)
let test_retention_final_snapshot_missing () =
  let lookup =
    answered
      254
      "An error occurred (DBSnapshotNotFound) when calling the DescribeDBSnapshots \
       operation"
  in
  (match classify_final_snapshot ~declared ~snapshot_id:"snap-1" lookup with
   | Sol_cli_aws_destruction.Settled (Retention_violated reason) ->
     Alcotest.(check bool)
       "the failure names the identifier and the declaration"
       true
       (contains "snap-1" reason && contains "final-snapshot" reason)
   | Sol_cli_aws_destruction.Settled _ | Sol_cli_aws_destruction.Pending _ ->
     Alcotest.fail "a missing promised snapshot must fail");
  (* A provider answer about a *different* snapshot is not evidence about this one. *)
  (match
     classify_final_snapshot
       ~declared
       ~snapshot_id:"snap-1"
       (final_snapshot
          {|{"DBSnapshots":[{"DBSnapshotIdentifier":"snap-other","SnapshotType":"manual","Status":"available"}]}|})
   with
   | Sol_cli_aws_destruction.Settled (Retention_violated _) -> ()
   | Sol_cli_aws_destruction.Settled _ | Sol_cli_aws_destruction.Pending _ ->
     Alcotest.fail "an answer about another snapshot must not establish this one");
  (* A snapshot the provider reports as failed is not a met guarantee either. *)
  match
    classify_final_snapshot
      ~declared
      ~snapshot_id:"snap-1"
      (final_snapshot
         {|{"DBSnapshots":[{"DBSnapshotIdentifier":"snap-1","SnapshotType":"manual","Status":"failed"}]}|})
  with
  | Sol_cli_aws_destruction.Settled (Retention_violated _) -> ()
  | Sol_cli_aws_destruction.Settled _ | Sol_cli_aws_destruction.Pending _ ->
    Alcotest.fail "a failed snapshot must not read as retained"
;;

(* Case 19: an unobservable final snapshot is a failure, and a snapshot still being
   created is reported as not-yet, never as retained. *)
let test_retention_final_snapshot_unknown () =
  (match
     classify_final_snapshot
       ~declared
       ~snapshot_id:"snap-1"
       (Unavailable "aws CLI missing")
   with
   | Sol_cli_aws_destruction.Settled (Retention_unknown _) -> ()
   | Sol_cli_aws_destruction.Settled _ | Sol_cli_aws_destruction.Pending _ ->
     Alcotest.fail "an unavailable provider is UNKNOWN, not success");
  (match
     classify_final_snapshot
       ~declared
       ~snapshot_id:"snap-1"
       (answered 1 "ERROR: request timed out")
   with
   | Sol_cli_aws_destruction.Settled (Retention_unknown _) -> ()
   | Sol_cli_aws_destruction.Settled _ | Sol_cli_aws_destruction.Pending _ ->
     Alcotest.fail "a timeout is UNKNOWN, not success");
  (* Still being created: "not yet", and the caller keeps observing. *)
  (match
     classify_final_snapshot
       ~declared
       ~snapshot_id:"snap-1"
       (final_snapshot
          {|{"DBSnapshots":[{"DBSnapshotIdentifier":"snap-1","SnapshotType":"manual","Status":"creating"}]}|})
   with
   | Sol_cli_aws_destruction.Pending message ->
     Alcotest.(check bool)
       "the pending report says what it is waiting for"
       true
       (contains "creating" message)
   | Sol_cli_aws_destruction.Settled _ ->
     Alcotest.fail "a snapshot still being created is not a met guarantee");
  (* And an UNKNOWN retention is a failure when combined, not a degraded success. *)
  let verdict =
    classify (observation ~retention:(Retention_unknown "the snapshot query failed") ())
  in
  Alcotest.(check bool) "retention UNKNOWN is not verified" false (is_verified verdict)
;;

(* Case 20: retain-nothing with no attributable artifact. *)
let test_retention_none_observed () =
  (match classify_instance_snapshots (final_snapshot {|{"DBSnapshots":[]}|}) with
   | Retention_required_and_observed evidence ->
     Alcotest.(check bool)
       "the observation says what was checked"
       true
       (contains "none observed" evidence)
   | retention ->
     Alcotest.failf "no residue must be observed, got %s" (retention_to_string retention));
  (* A database the provider reports as gone has no snapshot of it left. *)
  match
    classify_instance_snapshots
      (answered 254 "An error occurred (DBInstanceNotFound) when calling the operation")
  with
  | Retention_required_and_observed _ -> ()
  | retention ->
    Alcotest.failf
      "a gone instance retains nothing, got %s"
      (retention_to_string retention)
;;

(* Case 21: retain-nothing with residual snapshots. *)
let test_retention_none_residual () =
  match
    classify_instance_snapshots
      (final_snapshot
         {|{"DBSnapshots":[{"DBSnapshotIdentifier":"leaked-snap","SnapshotType":"manual","Status":"available"},{"DBSnapshotIdentifier":"leaked-auto","SnapshotType":"automated","Status":"available"}]}|})
  with
  | Retention_violated reason ->
    Alcotest.(check bool)
      "the failure names the residue and how many"
      true
      (contains "leaked-snap" reason
       && contains "leaked-auto" reason
       && contains "2 snapshot" reason)
  | retention ->
    Alcotest.failf "residual snapshots must fail, got %s" (retention_to_string retention)
;;

(* Case 22: retain-nothing that could not be observed. *)
let test_retention_none_unknown () =
  (match classify_instance_snapshots (Unavailable "aws CLI missing") with
   | Retention_unknown msg ->
     Alcotest.(check bool)
       "the unknown says what could not be observed"
       true
       (contains "no-residue" msg)
   | retention ->
     Alcotest.failf
       "an unavailable provider is UNKNOWN, got %s"
       (retention_to_string retention));
  match classify_instance_snapshots (answered 1 "ERROR: throttled") with
  | Retention_unknown _ -> ()
  | retention ->
    Alcotest.failf "a failed query is UNKNOWN, got %s" (retention_to_string retention)
;;

(* The report answers what an operator needs: what state says, what residue was
   found or could not be checked, and what retention was observed. *)
let test_report_is_diagnostic () =
  let obs =
    observation
      ~state:(state_evidence (Ok [ "google_container_cluster.main" ]))
      ~sweep:
        (Sweep_ran
           { residues = [ "the service-networking peering survived the destroy: p1" ]
           ; indeterminate = [ "the EBS volumes could not be checked" ]
           })
      ~retention:
        (Retention_violated "final-snapshot NOT observed: the snapshot does not exist")
      ()
  in
  let report = report obs in
  List.iter
    (fun (label, needle) -> Alcotest.(check bool) label true (contains needle report))
    [ "the state postcondition", "STILL REPRESENTS google_container_cluster.main"
    ; "the residue", "the service-networking peering survived the destroy"
    ; "the inconclusive check", "the EBS volumes could not be checked"
    ; "the retention violation", "final-snapshot NOT observed"
    ];
  Alcotest.(check bool)
    "an empty state names Terraform's authority (DEC-045)"
    true
    (contains "DEC-045" (Sol_cli_destroy_verification.report (observation ())));
  let verdict = classify obs in
  Alcotest.(check bool) "not verified" false (is_verified verdict);
  Alcotest.(check bool)
    "the verdict message states the violation"
    true
    (contains "violated" (verdict_message verdict))
;;

let () =
  Alcotest.run
    "destroy_verification"
    [ ( "state"
      , [ Alcotest.test_case "empty read is absence" `Quick test_state_empty
        ; Alcotest.test_case "residue is a violation" `Quick test_state_residue
        ; Alcotest.test_case "unreadable is UNKNOWN" `Quick test_state_unreadable
        ] )
    ; ( "combined"
      , [ Alcotest.test_case "clean is verified" `Quick test_combined_verified
        ; Alcotest.test_case "residue and inconclusive checks" `Quick test_sweep
        ; Alcotest.test_case
            "GCP not-found subject"
            `Quick
            test_gcp_not_found_subject_must_match
        ] )
    ; ( "retention"
      , [ Alcotest.test_case
            "final snapshot observed"
            `Quick
            test_retention_final_snapshot_observed
        ; Alcotest.test_case
            "final snapshot missing"
            `Quick
            test_retention_final_snapshot_missing
        ; Alcotest.test_case
            "final snapshot unknown"
            `Quick
            test_retention_final_snapshot_unknown
        ; Alcotest.test_case "retain-nothing observed" `Quick test_retention_none_observed
        ; Alcotest.test_case "retain-nothing residual" `Quick test_retention_none_residual
        ; Alcotest.test_case "retain-nothing unknown" `Quick test_retention_none_unknown
        ] )
    ; ( "report"
      , [ Alcotest.test_case "the report is diagnostic" `Quick test_report_is_diagnostic ]
      )
    ]
;;
