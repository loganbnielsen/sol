(* Offline tests for step 5's verification model (HARDEN-004).

   The claim under test is *epistemic*, not mechanical: what is Sol justified in
   concluding from what it observed? Two rules drive every case below.

     failure to obtain evidence is not evidence of the desired postcondition
     a successful destroy command is not itself evidence that the target is absent

   So the cases pin three things: a provider answer is PRESENT / ABSENT / UNKNOWN
   and UNKNOWN never becomes ABSENT; the Terraform-state postcondition is
   independent of both the provider answers and `terraform destroy`'s exit status;
   and the identities queried come from the inventory captured *before* destruction
   rather than from anything the target's configuration could supply.

   Every provider call is injected, so none of this needs terraform, gcloud, aws or
   a network. *)

open Sol_cli_destroy_verification

let contains needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec at i =
    needle_length = 0
    || (i + needle_length <= haystack_length
        && (String.sub haystack i needle_length = needle || at (i + 1)))
  in
  at 0
;;

let answered ?(stdout = "") status stderr = Answered { status; stdout; stderr }

let recipe_of ~provider identity =
  match query_of ~provider identity with
  | Queryable recipe -> recipe
  | No_recipe reason | Identity_incomplete reason ->
    Alcotest.failf "expected a recipe for %s: %s" identity.address reason
;;

(* ── The captured identities the cases query with ────────────────────────────
 *
 * Every field that the target's own configuration could also supply is set to a
 * deliberately *wrong* value, so a recipe that reconstructed an identity from
 * configuration instead of from the capture would build a different argv and fail
 * the assertion. *)

let gcp_cluster =
  { address = "google_container_cluster.main"
  ; kind = "google_container_cluster"
  ; provider_id =
      Some
        "https://container.googleapis.com/v1/projects/captured-project/locations/europe-west4/clusters/captured-cluster"
  ; arn = None
  ; project = Some "configured-project"
  ; region = Some "us-central1"
  }
;;

let gcp_sql =
  { address = "google_sql_database_instance.postgres"
  ; kind = "google_sql_database_instance"
  ; provider_id =
      Some
        "https://sqladmin.googleapis.com/sql/v1beta4/projects/captured-project/instances/captured-sql"
  ; arn = None
  ; project = Some "configured-project"
  ; region = Some "us-central1"
  }
;;

let aws_database =
  { address = "aws_db_instance.postgres"
  ; kind = "aws_db_instance"
  ; provider_id = Some "captured-instance"
  ; arn = Some "arn:aws:rds:eu-west-1:111122223333:db:captured-instance"
  ; project = Some "111122223333"
  ; region = Some "eu-west-1"
  }
;;

let aws_cluster =
  { address = "module.eks.aws_eks_cluster.this[0]"
  ; kind = "aws_eks_cluster"
  ; provider_id = Some "captured-cluster"
  ; arn = Some "arn:aws:eks:eu-west-1:111122223333:cluster/captured-cluster"
  ; project = Some "111122223333"
  ; region = Some "eu-west-1"
  }
;;

(* A kind with no lookup at all, for the coverage cases. *)
let gcp_iam_member =
  { address = "google_project_iam_member.provisioner_cluster_access"
  ; kind = "google_project_iam_member"
  ; provider_id = None
  ; arn = None
  ; project = Some "captured-project"
  ; region = None
  }
;;

(* No declared/state divergence: the plan declared nothing state did not
   represent. The B2 cases below supply [declared] explicitly. *)
let no_declared_obligations ~pre_state_empty =
  { pre_state_empty; read_failure = None; obligations = [] }
;;

let observation
      ?(state = State_absent)
      ?(identities = [])
      ?(unqueried = [])
      ?(declared = no_declared_obligations ~pre_state_empty:true)
      ?(sweep = Sweep_ran { residues = []; indeterminate = [] })
      ?(retention = Retention_not_required "this fixture declares no retention")
      ()
  =
  { state; identities; unqueried; declared; sweep; retention }
;;

let observation_of ~identity ~verdict =
  { identity
  ; operation = "test lookup"
  ; status = None
  ; evidence = "test evidence"
  ; verdict
  }
;;

(* ── Provider evidence: PRESENT / ABSENT / UNKNOWN ─────────────────────────── *)

(* Case 1: the provider's own explicit not-found is ABSENT. *)
let test_provider_not_found_is_absent () =
  let recipe = recipe_of ~provider:Sol_cli_provider.Aws aws_database in
  (match
     classify_lookup
       recipe
       (answered
          254
          "An error occurred (DBInstanceNotFound) when calling the DescribeDBInstances \
           operation: DBInstance not found")
   with
   | Absent -> ()
   | Present -> Alcotest.fail "an explicit not-found must not read as PRESENT"
   | Unknown reason -> Alcotest.failf "an explicit not-found must be ABSENT: %s" reason);
  (* GCP's explicit 404 wording, the one Attempt 4 found the old check could not
     recognise. *)
  let recipe = recipe_of ~provider:Sol_cli_provider.Gcp gcp_cluster in
  Alcotest.(check bool)
    "gcloud's 404 wording is ABSENT"
    true
    (classify_lookup
       recipe
       (answered
          1
          "ERROR: (gcloud.container.clusters.describe) ResponseError: code=404, \
           message=Not found: \
           projects/captured-project/locations/europe-west4/clusters/captured-cluster.")
     = Absent)
;;

(* Case 2: a returned resource is PRESENT. *)
let test_provider_resource_is_present () =
  let recipe = recipe_of ~provider:Sol_cli_provider.Gcp gcp_sql in
  Alcotest.(check string)
    "the Cloud SQL recipe uses the captured instance name"
    "gcloud sql instances describe captured-sql --project captured-project"
    recipe.operation;
  Alcotest.(check bool)
    "an answer about the resource is PRESENT"
    true
    (classify_lookup recipe (answered ~stdout:"RUNNABLE\n" 0 "") = Present)
;;

(* Cases 3-5: everything that is not an explicit not-found is UNKNOWN. *)
let test_provider_indeterminate_is_unknown () =
  let recipe = recipe_of ~provider:Sol_cli_provider.Gcp gcp_cluster in
  let unknown label lookup =
    match classify_lookup recipe lookup with
    | Unknown _ -> ()
    | Present -> Alcotest.failf "%s read as PRESENT" label
    | Absent -> Alcotest.failf "%s read as ABSENT" label
  in
  unknown
    "a permission failure"
    (answered
       1
       "ERROR: (gcloud.container.clusters.describe) PERMISSION_DENIED: caller does not \
        have permission");
  unknown
    "an authentication failure"
    (answered 1 "ERROR: reauthentication required; auth credentials expired");
  unknown "a timeout" (answered 1 "ERROR: request timed out after 30s");
  unknown "a transport failure" (answered 1 "ERROR: connection reset by peer");
  (* A 404 whose subject is a *different* project says nothing about our resource:
     GCP answers 404 for "that project is not visible" as well as for "the object
     is gone", which is how a wrong lookup becomes a false postcondition. *)
  unknown
    "a not-found naming another project"
    (answered
       1
       "ERROR: (gcloud.container.clusters.describe) ResponseError: code=404, message=Not \
        found: projects/other-project/locations/europe-west4/clusters/captured-cluster.");
  unknown
    "a not-found naming another project, quoted"
    (answered
       1
       "ERROR: The project 'other-project' was not found or you do not have access");
  unknown
    "a malformed/unclassifiable provider error"
    (answered 1 "ERROR: something happened");
  (* Nothing was asked at all. *)
  unknown "an unavailable tool" (Unavailable "gcloud could not be spawned: No such file")
;;

(* The subject rule's positive control: the same 404 naming the project this
   identity was captured in is absence. Without this, the tightened rule would be
   indistinguishable from a check that never recognises absence at all. *)
let test_gcp_not_found_subject_must_match () =
  let recipe = recipe_of ~provider:Sol_cli_provider.Gcp gcp_cluster in
  Alcotest.(check bool)
    "a 404 naming the captured project is ABSENT"
    true
    (classify_lookup
       recipe
       (answered
          1
          "ERROR: (gcloud.container.clusters.describe) ResponseError: code=404, \
           message=Not found: \
           projects/captured-project/locations/europe-west4/clusters/captured-cluster.")
     = Absent);
  (* A wording that names no project at all has no subject to contradict. *)
  Alcotest.(check bool)
    "a not-found naming no project is ABSENT"
    true
    (classify_lookup recipe (answered 1 "ERROR: NOT_FOUND: Resource was not found")
     = Absent);
  Alcotest.(check bool)
    "and the rule itself is not vacuous"
    false
    (gcp_absence_message
       ~project:"captured-project"
       "ERROR: code=404 Not found: projects/other-project/x");
  Alcotest.(check bool)
    "the same wording about our project is absence"
    true
    (gcp_absence_message
       ~project:"captured-project"
       "ERROR: code=404 Not found: projects/captured-project/x")
;;

(* Case 6: UNKNOWN never becomes absence -- neither in the per-identity verdict nor
   when the evidence is combined. *)
let test_provider_unknown_is_never_absence () =
  let verdict =
    classify
      (observation
         ~identities:
           [ observation_of ~identity:gcp_cluster ~verdict:(Unknown "permission denied") ]
         ())
  in
  Alcotest.(check (list string)) "no violation is invented" [] verdict.violations;
  Alcotest.(check int)
    "the unknown is carried as an unknown"
    1
    (List.length verdict.unknowns);
  Alcotest.(check bool) "and the destruction is not verified" false (is_verified verdict)
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

(* Case 10: state empty + provider ABSENT -> verified absence. *)
let test_combined_verified () =
  let verdict =
    classify
      (observation
         ~identities:
           [ observation_of ~identity:gcp_cluster ~verdict:Absent
           ; observation_of ~identity:gcp_sql ~verdict:Absent
           ]
         ())
  in
  Alcotest.(check (list string)) "nothing violated" [] verdict.violations;
  Alcotest.(check (list string)) "nothing unknown" [] verdict.unknowns;
  Alcotest.(check bool) "verified" true (is_verified verdict)
;;

(* Case 11: state empty + provider PRESENT -> failure; provider residue. *)
let test_combined_provider_present () =
  let verdict =
    classify
      (observation
         ~identities:[ observation_of ~identity:gcp_cluster ~verdict:Present ]
         ())
  in
  Alcotest.(check int) "the residue is a violation" 1 (List.length verdict.violations);
  Alcotest.(check bool)
    "the violation names the identity and the query"
    true
    (let message = List.hd verdict.violations in
     contains "google_container_cluster.main" message && contains "test lookup" message);
  Alcotest.(check bool) "not verified" false (is_verified verdict)
;;

(* Case 12: state empty + provider UNKNOWN -> failure, NOT success. *)
let test_combined_provider_unknown () =
  let verdict =
    classify
      (observation
         ~identities:[ observation_of ~identity:gcp_cluster ~verdict:(Unknown "timeout") ]
         ())
  in
  Alcotest.(check (list string)) "no positive violation" [] verdict.violations;
  Alcotest.(check int) "an unproven postcondition" 1 (List.length verdict.unknowns);
  Alcotest.(check bool) "UNKNOWN is not a success" false (is_verified verdict)
;;

(* Case 13: state still represented + provider ABSENT -> state residue. *)
let test_combined_state_residue () =
  let verdict =
    classify
      (observation
         ~state:(state_evidence (Ok [ "google_sql_database_instance.postgres" ]))
         ~identities:[ observation_of ~identity:gcp_sql ~verdict:Absent ]
         ())
  in
  Alcotest.(check int)
    "the state residue is the violation"
    1
    (List.length verdict.violations);
  Alcotest.(check (list string))
    "and the provider answer adds no unknown"
    []
    verdict.unknowns;
  Alcotest.(check bool) "not verified" false (is_verified verdict)
;;

(* Case 14: state unreadable + provider ABSENT -> still not a clean success. *)
let test_combined_state_unreadable () =
  let verdict =
    classify
      (observation
         ~state:(state_evidence (Error "invalid `terraform show -json`"))
         ~identities:[ observation_of ~identity:gcp_cluster ~verdict:Absent ]
         ())
  in
  Alcotest.(check bool) "not verified" false (is_verified verdict);
  Alcotest.(check int)
    "the unreadable state is the unknown"
    1
    (List.length verdict.unknowns)
;;

(* ── Identity: captured, never reconstructed ───────────────────────────────── *)

(* Case 15: the recipes query the captured id/project/region, not the configured
   ones. [gcp_cluster] and [aws_cluster] carry deliberately wrong configured values,
   so these assertions fail if a recipe falls back to configuration. *)
let test_identity_is_captured_not_configured () =
  let gcp = recipe_of ~provider:Sol_cli_provider.Gcp gcp_cluster in
  Alcotest.(check string)
    "the GCP query asks about the captured cluster in the captured project and location"
    "gcloud container clusters describe captured-cluster --location europe-west4 \
     --project captured-project"
    gcp.operation;
  Alcotest.(check bool)
    "not the configured region"
    false
    (contains "us-central1" gcp.operation);
  Alcotest.(check bool)
    "not the configured project"
    false
    (contains "configured-project" gcp.operation);
  let aws = recipe_of ~provider:Sol_cli_provider.Aws aws_cluster in
  Alcotest.(check string)
    "the AWS query asks about the captured cluster in the region from its ARN"
    "aws eks describe-cluster --name captured-cluster --region eu-west-1"
    aws.operation;
  (* The region the ARN carries is what the inventory records. *)
  Alcotest.(check (option string))
    "the ARN's region is read from the ARN"
    (Some "eu-west-1")
    (region_of_arn "arn:aws:eks:eu-west-1:111122223333:cluster/captured-cluster");
  Alcotest.(check (option string))
    "and the ARN's account"
    (Some "111122223333")
    (account_of_arn "arn:aws:eks:eu-west-1:111122223333:cluster/captured-cluster");
  Alcotest.(check (option string))
    "the object name comes from the captured identity"
    (Some "captured-cluster")
    (object_name gcp_cluster)
;;

(* Case 16: a name-based orphan sweep cannot override the captured identities'
   evidence, in either direction. *)
let test_sweep_cannot_override_captured_evidence () =
  (* A sweep that found nothing cannot explain away a PRESENT identity. *)
  let verdict =
    classify
      (observation
         ~identities:[ observation_of ~identity:gcp_cluster ~verdict:Present ]
         ~sweep:(Sweep_ran { residues = []; indeterminate = [] })
         ())
  in
  Alcotest.(check int)
    "a clean sweep leaves the PRESENT violation standing"
    1
    (List.length verdict.violations);
  (* ... nor turn an UNKNOWN identity into a pass. *)
  let verdict =
    classify
      (observation
         ~identities:
           [ observation_of ~identity:gcp_cluster ~verdict:(Unknown "auth failed") ]
         ~sweep:(Sweep_ran { residues = []; indeterminate = [] })
         ())
  in
  Alcotest.(check bool)
    "a clean sweep does not verify an UNKNOWN identity"
    false
    (is_verified verdict);
  (* An inconclusive sweep is reported, and is not itself a violation. *)
  let verdict =
    classify
      (observation
         ~sweep:
           (Sweep_ran
              { residues = []
              ; indeterminate = [ "the sweep could not establish its query context" ]
              })
         ())
  in
  Alcotest.(check (list string))
    "an inconclusive sweep is not a violation"
    []
    verdict.violations;
  Alcotest.(check bool)
    "and does not by itself block an otherwise-verified result"
    true
    (is_verified verdict);
  (* A sweep that *found* something is a violation. *)
  let verdict =
    classify
      (observation
         ~sweep:(Sweep_ran { residues = [ "AWS EIPs remain" ]; indeterminate = [] })
         ())
  in
  Alcotest.(check int) "a residue is a violation" 1 (List.length verdict.violations)
;;

(* The coverage statement: a kind with no lookup is reported, not silently dropped,
   and is not by itself a failure. *)
let test_unqueried_kinds_are_reported () =
  (match query_of ~provider:Sol_cli_provider.Gcp gcp_iam_member with
   | No_recipe reason ->
     Alcotest.(check bool)
       "the reason names the kind"
       true
       (contains "google_project_iam_member" reason)
   | Queryable _ | Identity_incomplete _ ->
     Alcotest.fail "a kind with no lookup must be No_recipe, not a queryable identity");
  (* A queryable kind whose captured identity is not enough is UNKNOWN, not a
     silent skip -- the two must not collapse. *)
  let incomplete = { gcp_cluster with provider_id = None } in
  (match query_of ~provider:Sol_cli_provider.Gcp incomplete with
   | Identity_incomplete reason ->
     Alcotest.(check bool)
       "the reason says what is missing"
       true
       (contains "self-link" reason)
   | Queryable _ | No_recipe _ ->
     Alcotest.fail "an incomplete captured identity must be UNKNOWN");
  let verdict =
    classify
      (observation
         ~unqueried:
           [ ( gcp_iam_member
             , "no GCP provider lookup is defined for google_project_iam_member" )
           ]
         ())
  in
  Alcotest.(check bool)
    "coverage alone leaves the state postcondition standing"
    true
    (is_verified verdict)
;;

(* ── Retention, observed rather than printed ───────────────────────────────── *)

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
  | Settled (Retention_required_and_observed evidence) ->
    Alcotest.(check bool)
      "the observation names the identifier and the state"
      true
      (contains "snap-1" evidence && contains "available" evidence)
  | Settled _ -> Alcotest.fail "an available snapshot is a met retention guarantee"
  | Pending message -> Alcotest.failf "an available snapshot is not pending: %s" message
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
   | Settled (Retention_violated reason) ->
     Alcotest.(check bool)
       "the failure names the identifier and the declaration"
       true
       (contains "snap-1" reason && contains "final-snapshot" reason)
   | Settled _ | Pending _ -> Alcotest.fail "a missing promised snapshot must fail");
  (* A provider answer about a *different* snapshot is not evidence about this one. *)
  (match
     classify_final_snapshot
       ~declared
       ~snapshot_id:"snap-1"
       (final_snapshot
          {|{"DBSnapshots":[{"DBSnapshotIdentifier":"snap-other","SnapshotType":"manual","Status":"available"}]}|})
   with
   | Settled (Retention_violated _) -> ()
   | Settled _ | Pending _ ->
     Alcotest.fail "an answer about another snapshot must not establish this one");
  (* A snapshot the provider reports as failed is not a met guarantee either. *)
  match
    classify_final_snapshot
      ~declared
      ~snapshot_id:"snap-1"
      (final_snapshot
         {|{"DBSnapshots":[{"DBSnapshotIdentifier":"snap-1","SnapshotType":"manual","Status":"failed"}]}|})
  with
  | Settled (Retention_violated _) -> ()
  | Settled _ | Pending _ -> Alcotest.fail "a failed snapshot must not read as retained"
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
   | Settled (Retention_unknown _) -> ()
   | Settled _ | Pending _ ->
     Alcotest.fail "an unavailable provider is UNKNOWN, not success");
  (match
     classify_final_snapshot
       ~declared
       ~snapshot_id:"snap-1"
       (answered 1 "ERROR: request timed out")
   with
   | Settled (Retention_unknown _) -> ()
   | Settled _ | Pending _ -> Alcotest.fail "a timeout is UNKNOWN, not success");
  (* Still being created: "not yet", and the caller keeps observing. *)
  (match
     classify_final_snapshot
       ~declared
       ~snapshot_id:"snap-1"
       (final_snapshot
          {|{"DBSnapshots":[{"DBSnapshotIdentifier":"snap-1","SnapshotType":"manual","Status":"creating"}]}|})
   with
   | Pending message ->
     Alcotest.(check bool)
       "the pending report says what it is waiting for"
       true
       (contains "creating" message)
   | Settled _ -> Alcotest.fail "a snapshot still being created is not a met guarantee");
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

(* The report has to answer the diagnostic questions, so it is asserted rather than
   assumed: what was expected absent, which identity was queried, what came back,
   how it was classified, what state says, and what remains unproven. *)
let test_report_is_diagnostic () =
  let observation =
    observation
      ~state:(state_evidence (Ok [ "google_container_cluster.main" ]))
      ~identities:
        [ { identity = gcp_cluster
          ; operation = "gcloud container clusters describe captured-cluster"
          ; status = Some 1
          ; evidence = "code=404 not found"
          ; verdict = Absent
          }
        ; observation_of ~identity:gcp_sql ~verdict:(Unknown "permission denied")
        ]
      ~unqueried:
        [ ( gcp_iam_member
          , "no GCP provider lookup is defined for google_project_iam_member" )
        ]
      ~sweep:(Sweep_ran { residues = []; indeterminate = [ "no VPC identity captured" ] })
      ~retention:
        (Retention_violated "final-snapshot NOT observed: the snapshot does not exist")
      ()
  in
  let report = report observation in
  List.iter
    (fun (label, needle) -> Alcotest.(check bool) label true (contains needle report))
    [ "the state postcondition", "STILL REPRESENTS google_container_cluster.main"
    ; "the queried identity", "google_container_cluster.main"
    ; "the exact query", "gcloud container clusters describe captured-cluster"
    ; "the provider's own answer", "code=404 not found"
    ; "the classification", "ABSENT"
    ; "the unknown classification", "UNKNOWN"
    ; "the coverage gap", "not provider-verified"
    ; "the inconclusive sweep", "no VPC identity captured"
    ; "the retention violation", "final-snapshot NOT observed"
    ];
  (* The verdict is the report's summary, and it must not claim success. *)
  let verdict = classify observation in
  Alcotest.(check bool)
    "the report's observation is not verified"
    false
    (is_verified verdict);
  Alcotest.(check bool)
    "the verdict message states violation before unknown"
    true
    (contains "violated" (verdict_message verdict))
;;

(* ── The declared identity source (FND-0055 / B2) ─────────────────────────────
 *
 * A resource the root declares but the pre-destroy state does not represent has
 * no captured identity. Its query is built from the plan's own declared values,
 * and the cases below pin both halves: what a declaration *can* establish, and
 * what it must refuse to invent. *)

(* A declared resource with the given address and kind. [address] is dropped from
   the query anyway -- it is the obligation's identity, not query material. *)
let declared_resource address kind json =
  { address; kind; values = Yojson.Safe.from_string json }
;;

let declared_recipe ?target_project ?target_region ~provider declared =
  match declared_query_of ~provider ~target_project ~target_region declared with
  | Queryable recipe -> recipe
  | No_recipe reason | Identity_incomplete reason ->
    Alcotest.failf "expected a declared recipe for %s: %s" declared.address reason
;;

let captured_recipe ~provider identity =
  match query_of ~provider identity with
  | Queryable recipe -> recipe
  | No_recipe reason | Identity_incomplete reason ->
    Alcotest.failf "expected a captured recipe for %s: %s" identity.address reason
;;

let declared_observed
      ?(operation = "test declared lookup")
      ?(evidence = "test evidence")
      ~address
      ~kind
      verdict
  =
  { address
  ; kind
  ; requirement =
      Declared_observed
        { identity =
            { address
            ; kind
            ; provider_id = None
            ; arn = None
            ; project = None
            ; region = None
            }
        ; operation
        ; status = None
        ; evidence
        ; verdict
        }
  }
;;

let declared_unqueryable ~address ~kind reason =
  { address; kind; requirement = Declared_unqueryable reason }
;;

let coverage ?(pre_state_empty = false) ?(read_failure = None) obligations =
  { pre_state_empty; read_failure; obligations }
;;

(* Case A1: the planned values Terraform computes from the configuration are
   enough to build the query, in the declared scope. *)
let test_declared_recipe_from_planned_values () =
  let cluster =
    declared_recipe
      ~provider:Sol_cli_provider.Gcp
      ~target_project:"sol-qualification"
      (declared_resource
         "google_container_cluster.main"
         "google_container_cluster"
         {|{"name":"sol-qual","location":"us-central1"}|})
  in
  Alcotest.(check string)
    "the GKE query"
    "gcloud container clusters describe sol-qual --location us-central1 --project \
     sol-qualification"
    cluster.operation;
  let registry =
    declared_recipe
      ~provider:Sol_cli_provider.Gcp
      ~target_project:"sol-qualification"
      (declared_resource
         "google_artifact_registry_repository.images"
         "google_artifact_registry_repository"
         {|{"repository_id":"sol-qual","location":"us-central1"}|})
  in
  Alcotest.(check string)
    "the Artifact Registry query uses the configured repository id"
    "gcloud artifacts repositories describe sol-qual --location us-central1 --project \
     sol-qualification"
    registry.operation;
  (* AWS: the planned values carry the name, and the region is the target's
     provider scope, because an AWS resource type does not record its own. *)
  let eks =
    declared_recipe
      ~provider:Sol_cli_provider.Aws
      ~target_region:"us-east-1"
      (declared_resource
         "module.eks.aws_eks_cluster.this[0]"
         "aws_eks_cluster"
         {|{"name":"sol-qual"}|})
  in
  Alcotest.(check string)
    "the EKS query"
    "aws eks describe-cluster --name sol-qual --region us-east-1"
    eks.operation;
  let bucket =
    declared_recipe
      ~provider:Sol_cli_provider.Aws
      (declared_resource
         "aws_s3_bucket.loki"
         "aws_s3_bucket"
         {|{"bucket":"sol-qual-loki"}|})
  in
  Alcotest.(check string)
    "the S3 query needs no region"
    "aws s3api get-bucket-location --bucket sol-qual-loki"
    bucket.operation
;;

(* Case A2: a declared identity that cannot be built is UNKNOWN. A
   provider-assigned id is never fabricated, and a value the plan does not carry
   is never defaulted. *)
let test_declared_identity_never_fabricated () =
  (match
     declared_query_of
       ~provider:Sol_cli_provider.Aws
       ~target_project:None
       ~target_region:(Some "us-east-1")
       (declared_resource "aws_vpc.main" "aws_vpc" {|{"cidr_block":"10.0.0.0/16"}|})
   with
   | Identity_incomplete reason ->
     Alcotest.(check bool)
       "the reason names the address"
       true
       (contains "aws_vpc.main" reason)
   | Queryable recipe ->
     Alcotest.failf "a provider-assigned id must never be fabricated: %s" recipe.operation
   | No_recipe reason -> Alcotest.failf "expected an incomplete identity: %s" reason);
  List.iter
    (fun (label, declared) ->
       match
         declared_query_of
           ~provider:Sol_cli_provider.Gcp
           ~target_project:(Some "sol-qualification")
           ~target_region:None
           declared
       with
       | Identity_incomplete _ -> ()
       | Queryable recipe ->
         Alcotest.failf "%s: a query was built anyway: %s" label recipe.operation
       | No_recipe reason ->
         Alcotest.failf "%s: expected an incomplete identity: %s" label reason)
    [ ( "the location is absent"
      , declared_resource
          "google_container_cluster.main"
          "google_container_cluster"
          {|{"name":"sol-qual"}|} )
    ; ( "the name is not a string"
      , declared_resource
          "google_container_cluster.main"
          "google_container_cluster"
          {|{"name":42,"location":"us-central1"}|} )
    ; ( "the resource declares no values at all"
      , declared_resource
          "google_container_cluster.main"
          "google_container_cluster"
          "null" )
    ; ( "the values are not an object"
      , declared_resource "google_container_cluster.main" "google_container_cluster" "[]"
      )
    ];
  (* No project anywhere means no scope to query in, so there is no query. *)
  match
    declared_query_of
      ~provider:Sol_cli_provider.Gcp
      ~target_project:None
      ~target_region:None
      (declared_resource
         "google_compute_network.main"
         "google_compute_network"
         {|{"name":"sol-qual"}|})
  with
  | Identity_incomplete _ -> ()
  | Queryable recipe -> Alcotest.failf "a query without a project: %s" recipe.operation
  | No_recipe _ -> Alcotest.fail "a network lookup is defined"
;;

(* Case A3: a kind with no declared lookup is a coverage statement, not a guess. *)
let test_declared_unknown_kinds_have_no_recipe () =
  List.iter
    (fun (provider, kind) ->
       match
         declared_query_of
           ~provider
           ~target_project:None
           ~target_region:None
           (declared_resource ("declared." ^ kind) kind "{}")
       with
       | No_recipe reason ->
         Alcotest.(check bool) "the reason names the kind" true (contains kind reason)
       | Queryable recipe ->
         Alcotest.failf "a query was built for %s: %s" kind recipe.operation
       | Identity_incomplete reason ->
         Alcotest.failf "expected No_recipe for %s: %s" kind reason)
    [ Sol_cli_provider.Gcp, "google_compute_firewall"
    ; Sol_cli_provider.Gcp, "google_project_iam_member"
    ; Sol_cli_provider.Aws, "aws_iam_role"
    ]
;;

(* Case A4: the two identity sources must build the same query for the same
   object. A drift between them would be a bug in one of them, and the declared
   path is the one added here. *)
let test_declared_matches_captured () =
  let gcp label ~project kind link json =
    let identity =
      { address = ""
      ; kind
      ; provider_id = Some link
      ; arn = None
      ; project = Some project
      ; region = None
      }
    in
    let captured = captured_recipe ~provider:Sol_cli_provider.Gcp identity in
    let declared =
      declared_recipe
        ~provider:Sol_cli_provider.Gcp
        ~target_project:project
        (declared_resource "" kind json)
    in
    Alcotest.(check string) ("gcp " ^ label) captured.operation declared.operation
  in
  let aws label ?region kind id arn json =
    let identity =
      { address = ""
      ; kind
      ; provider_id = Some id
      ; arn = Some arn
      ; project = None
      ; region
      }
    in
    let captured = captured_recipe ~provider:Sol_cli_provider.Aws identity in
    let declared =
      declared_recipe
        ~provider:Sol_cli_provider.Aws
        ?target_region:region
        (declared_resource "" kind json)
    in
    Alcotest.(check string) ("aws " ^ label) captured.operation declared.operation
  in
  let p = "sol-qualification" in
  gcp
    "cluster"
    ~project:p
    "google_container_cluster"
    "https://container.googleapis.com/v1/projects/sol-qualification/locations/us-central1/clusters/sol-qual"
    {|{"name":"sol-qual","location":"us-central1"}|};
  gcp
    "sql"
    ~project:p
    "google_sql_database_instance"
    "https://sqladmin.googleapis.com/sql/v1beta4/projects/sol-qualification/instances/sol-qual-postgres"
    {|{"name":"sol-qual-postgres"}|};
  gcp
    "network"
    ~project:p
    "google_compute_network"
    "https://www.googleapis.com/compute/v1/projects/sol-qualification/global/networks/sol-qual"
    {|{"name":"sol-qual"}|};
  gcp
    "subnetwork"
    ~project:p
    "google_compute_subnetwork"
    "https://www.googleapis.com/compute/v1/projects/sol-qualification/regions/us-central1/subnetworks/sol-qual-nodes"
    {|{"name":"sol-qual-nodes","region":"us-central1"}|};
  gcp
    "router"
    ~project:p
    "google_compute_router"
    "https://www.googleapis.com/compute/v1/projects/sol-qualification/regions/us-central1/routers/sol-qual"
    {|{"name":"sol-qual","region":"us-central1"}|};
  gcp
    "regional address"
    ~project:p
    "google_compute_address"
    "https://www.googleapis.com/compute/v1/projects/sol-qualification/regions/us-central1/addresses/sol-qual-ip"
    {|{"name":"sol-qual-ip","region":"us-central1"}|};
  gcp
    "global address"
    ~project:p
    "google_compute_global_address"
    "https://www.googleapis.com/compute/v1/projects/sol-qualification/global/addresses/sol-qual-sql-peering"
    {|{"name":"sol-qual-sql-peering"}|};
  gcp
    "artifact registry"
    ~project:p
    "google_artifact_registry_repository"
    "projects/sol-qualification/locations/us-central1/repositories/sol-qual"
    {|{"repository_id":"sol-qual","location":"us-central1"}|};
  (* A bucket's self-link carries no project, so its captured identity needs one
     recorded -- which the inventory does carry. *)
  gcp
    "bucket"
    ~project:p
    "google_storage_bucket"
    "https://www.googleapis.com/storage/v1/b/sol-qual-loki"
    {|{"name":"sol-qual-loki"}|};
  gcp
    "dns zone"
    ~project:p
    "google_dns_managed_zone"
    "projects/sol-qualification/managedZones/sol-qual-zone"
    {|{"name":"sol-qual-zone"}|};
  aws
    "eks cluster"
    ~region:"us-east-1"
    "aws_eks_cluster"
    "sol-qual"
    "arn:aws:eks:us-east-1:111122223333:cluster/sol-qual"
    {|{"name":"sol-qual"}|};
  aws
    "db instance"
    ~region:"us-east-1"
    "aws_db_instance"
    "sol-qual-postgres"
    "arn:aws:rds:us-east-1:111122223333:db:sol-qual-postgres"
    {|{"identifier":"sol-qual-postgres"}|};
  aws
    "ecr repository"
    ~region:"us-east-1"
    "aws_ecr_repository"
    "sol-qual/checkout"
    "arn:aws:ecr:us-east-1:111122223333:repository/sol-qual/checkout"
    {|{"name":"sol-qual/checkout"}|};
  aws
    "s3 bucket"
    "aws_s3_bucket"
    "sol-qual-loki"
    "arn:aws:s3:::sol-qual-loki"
    {|{"bucket":"sol-qual-loki"}|}
;;

(* ── The declared universe's obligations ─────────────────────────────────────
 *
 * The negative property this exists for: `declared && !state_represented` must
 * never silently fall out of the verification set. *)

(* Case B1: declared + state-absent + PROVIDER PRESENT -> violation. *)
let test_declared_present_is_a_violation () =
  let verdict =
    classify
      (observation
         ~declared:
           (coverage
              [ declared_observed
                  ~address:"google_artifact_registry_repository.images"
                  ~kind:"google_artifact_registry_repository"
                  Present
              ])
         ())
  in
  Alcotest.(check int) "the divergence is a violation" 1 (List.length verdict.violations);
  Alcotest.(check bool) "and it is not verified" false (is_verified verdict);
  Alcotest.(check bool)
    "the violation names the address and the query"
    true
    (let message = List.hd verdict.violations in
     contains "google_artifact_registry_repository.images" message
     && contains "test declared lookup" message);
  (* Positive evidence is positive evidence whatever the state looked like: an
     empty pre-state must not soften a PRESENT answer into success. *)
  let verdict =
    classify
      (observation
         ~declared:
           (coverage
              ~pre_state_empty:true
              [ declared_observed
                  ~address:"aws_db_instance.postgres"
                  ~kind:"aws_db_instance"
                  Present
              ])
         ())
  in
  Alcotest.(check int)
    "PRESENT from an empty pre-state is still a violation"
    1
    (List.length verdict.violations);
  Alcotest.(check bool) "and it is not verified" false (is_verified verdict)
;;

(* Case B2: declared + state-absent + PROVIDER ABSENT -> the obligation is met. *)
let test_declared_absent_satisfies () =
  let verdict =
    classify
      (observation
         ~declared:
           (coverage
              [ declared_observed
                  ~address:"google_compute_subnetwork.main"
                  ~kind:"google_compute_subnetwork"
                  Absent
              ])
         ())
  in
  Alcotest.(check (list string)) "nothing violated" [] verdict.violations;
  Alcotest.(check (list string)) "nothing unknown" [] verdict.unknowns;
  Alcotest.(check bool) "verified" true (is_verified verdict)
;;

(* Case B3: declared + state-absent + a query that was attempted and returned
   UNKNOWN -> failure, from either pre-state. *)
let test_declared_unknown_fails () =
  let verdict =
    classify
      (observation
         ~declared:
           (coverage
              [ declared_observed
                  ~address:"google_artifact_registry_repository.images"
                  ~kind:"google_artifact_registry_repository"
                  (Unknown "the provider answered exit 403")
              ])
         ())
  in
  Alcotest.(check (list string)) "no invented violation" [] verdict.violations;
  Alcotest.(check int)
    "an attempted query that returned UNKNOWN is an unknown"
    1
    (List.length verdict.unknowns);
  Alcotest.(check bool) "not verified" false (is_verified verdict);
  let verdict =
    classify
      (observation
         ~declared:
           (coverage
              ~pre_state_empty:true
              [ declared_observed
                  ~address:"google_artifact_registry_repository.images"
                  ~kind:"google_artifact_registry_repository"
                  (Unknown "throttled")
              ])
         ())
  in
  Alcotest.(check bool)
    "an attempted query fails even from an empty pre-state"
    false
    (is_verified verdict)
;;

(* Case B4: declared + state-absent + no query could be built, with a state that
   represented something: failure. *)
let test_declared_unqueryable_fails_when_state_was_represented () =
  let verdict =
    classify
      (observation
         ~declared:
           (coverage
              [ declared_unqueryable
                  ~address:"google_project_iam_member.provisioner_cluster_access"
                  ~kind:"google_project_iam_member"
                  "no GCP provider lookup is defined for google_project_iam_member"
              ])
         ())
  in
  Alcotest.(check int)
    "the unqueryable declaration is an unknown"
    1
    (List.length verdict.unknowns);
  Alcotest.(check bool) "not verified" false (is_verified verdict);
  Alcotest.(check bool)
    "the reason says state did not represent it"
    true
    (contains "does not represent it" (List.hd verdict.unknowns))
;;

(* Case B5: the one carve-out. An empty pre-destroy state cannot distinguish
   "this target was never applied" from "its whole state was lost", so an
   unqueryable declaration from it is a recorded limitation -- not a failure, and
   never absence. *)
let test_declared_unqueryable_from_empty_state_is_a_limitation () =
  let observation =
    observation
      ~declared:
        (coverage
           ~pre_state_empty:true
           [ declared_unqueryable
               ~address:"google_project_iam_member.provisioner_cluster_access"
               ~kind:"google_project_iam_member"
               "no GCP provider lookup is defined for google_project_iam_member"
           ])
      ()
  in
  let verdict = classify observation in
  Alcotest.(check (list string)) "no violation" [] verdict.violations;
  Alcotest.(check (list string)) "no unknown" [] verdict.unknowns;
  Alcotest.(check bool) "the empty-state no-op is preserved" true (is_verified verdict);
  let report = report observation in
  Alcotest.(check bool)
    "the limitation is named as one"
    true
    (contains "coverage limitation" report);
  Alcotest.(check bool)
    "and the address is named"
    true
    (contains "google_project_iam_member.provisioner_cluster_access" report);
  Alcotest.(check bool)
    "and it is never read as absence"
    true
    (contains "not read as absence" report)
;;

(* Case B6: the read-only plan itself could not be read. A failed observation, not
   an absent capability -- so it fails whatever the state looked like. *)
let test_declared_read_failure_fails () =
  let verdict =
    classify
      (observation
         ~declared:(coverage ~read_failure:(Some "a read-only plan exited 1") [])
         ())
  in
  Alcotest.(check int)
    "the unreadable plan is an unknown"
    1
    (List.length verdict.unknowns);
  Alcotest.(check bool) "not verified" false (is_verified verdict);
  Alcotest.(check bool)
    "it says what could not be established"
    true
    (contains "could not be established from a read-only plan" (List.hd verdict.unknowns))
;;

(* Case B7: the operator output answers the question the old silence avoided. *)
let test_declared_report_is_diagnostic () =
  let observation =
    observation
      ~declared:
        (coverage
           [ declared_observed
               ~address:"google_artifact_registry_repository.images"
               ~kind:"google_artifact_registry_repository"
               ~operation:
                 "gcloud artifacts repositories describe sol-qual --location us-central1 \
                  --project sol-qualification"
               ~evidence:"code=404 not found"
               Present
           ])
      ()
  in
  let report = report observation in
  List.iter
    (fun (label, needle) -> Alcotest.(check bool) label true (contains needle report))
    [ "the divergence header", "declared but not represented in Terraform state"
    ; "the address", "google_artifact_registry_repository.images"
    ; "the observation", "provider observation: PRESENT"
    ; ( "the exact query"
      , "gcloud artifacts repositories describe sol-qual --location us-central1 \
         --project sol-qualification" )
    ; "the consequence", "destruction postcondition not established"
    ];
  (* The report never carries a planned value: the observation holds none, and only
     the address and the safe query identity can reach it. *)
  Alcotest.(check bool)
    "no planned values are echoed"
    false
    (contains "db_password" report)
;;

let () =
  Alcotest.run
    "destroy_verification"
    [ ( "provider evidence"
      , [ Alcotest.test_case
            "explicit not-found is ABSENT"
            `Quick
            test_provider_not_found_is_absent
        ; Alcotest.test_case
            "a returned resource is PRESENT"
            `Quick
            test_provider_resource_is_present
        ; Alcotest.test_case
            "everything else is UNKNOWN"
            `Quick
            test_provider_indeterminate_is_unknown
        ; Alcotest.test_case
            "a not-found must be about our project"
            `Quick
            test_gcp_not_found_subject_must_match
        ; Alcotest.test_case
            "UNKNOWN is never absence"
            `Quick
            test_provider_unknown_is_never_absence
        ] )
    ; ( "terraform state postcondition"
      , [ Alcotest.test_case "empty read is absence" `Quick test_state_empty
        ; Alcotest.test_case "residue is a violation" `Quick test_state_residue
        ; Alcotest.test_case "unreadable is UNKNOWN" `Quick test_state_unreadable
        ] )
    ; ( "combined evidence"
      , [ Alcotest.test_case
            "state empty + absent is verified"
            `Quick
            test_combined_verified
        ; Alcotest.test_case
            "state empty + present fails"
            `Quick
            test_combined_provider_present
        ; Alcotest.test_case
            "state empty + unknown fails"
            `Quick
            test_combined_provider_unknown
        ; Alcotest.test_case "state residue fails" `Quick test_combined_state_residue
        ; Alcotest.test_case
            "unreadable state is not a clean success"
            `Quick
            test_combined_state_unreadable
        ] )
    ; ( "identity"
      , [ Alcotest.test_case
            "captured, not configured"
            `Quick
            test_identity_is_captured_not_configured
        ; Alcotest.test_case
            "the sweep cannot override captured evidence"
            `Quick
            test_sweep_cannot_override_captured_evidence
        ; Alcotest.test_case
            "coverage gaps are reported"
            `Quick
            test_unqueried_kinds_are_reported
        ] )
    ; ( "retention"
      , [ Alcotest.test_case
            "final snapshot observed"
            `Quick
            test_retention_final_snapshot_observed
        ; Alcotest.test_case
            "final snapshot missing fails"
            `Quick
            test_retention_final_snapshot_missing
        ; Alcotest.test_case
            "final snapshot unknown fails"
            `Quick
            test_retention_final_snapshot_unknown
        ; Alcotest.test_case "retain-nothing observed" `Quick test_retention_none_observed
        ; Alcotest.test_case
            "retain-nothing residue fails"
            `Quick
            test_retention_none_residual
        ; Alcotest.test_case
            "retain-nothing unknown fails"
            `Quick
            test_retention_none_unknown
        ] )
    ; ( "diagnostics"
      , [ Alcotest.test_case "the report is diagnostic" `Quick test_report_is_diagnostic ]
      )
    ; ( "the declared identity source (B2)"
      , [ Alcotest.test_case
            "planned values build the provider query"
            `Quick
            test_declared_recipe_from_planned_values
        ; Alcotest.test_case
            "an incomplete declared identity is UNKNOWN"
            `Quick
            test_declared_identity_never_fabricated
        ; Alcotest.test_case
            "a kind with no declared lookup is No_recipe"
            `Quick
            test_declared_unknown_kinds_have_no_recipe
        ; Alcotest.test_case
            "the declared and captured queries agree"
            `Quick
            test_declared_matches_captured
        ] )
    ; ( "the declared universe's obligations"
      , [ Alcotest.test_case
            "declared + state-absent + PRESENT is a violation"
            `Quick
            test_declared_present_is_a_violation
        ; Alcotest.test_case
            "declared + state-absent + ABSENT is satisfied"
            `Quick
            test_declared_absent_satisfies
        ; Alcotest.test_case
            "declared + state-absent + UNKNOWN fails"
            `Quick
            test_declared_unknown_fails
        ; Alcotest.test_case
            "an unqueryable declared resource fails"
            `Quick
            test_declared_unqueryable_fails_when_state_was_represented
        ; Alcotest.test_case
            "from an empty state it is a coverage limitation"
            `Quick
            test_declared_unqueryable_from_empty_state_is_a_limitation
        ; Alcotest.test_case
            "an unreadable plan fails closed"
            `Quick
            test_declared_read_failure_fails
        ; Alcotest.test_case
            "the declared report is diagnostic"
            `Quick
            test_declared_report_is_diagnostic
        ] )
    ]
;;
