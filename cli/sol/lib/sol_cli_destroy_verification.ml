(* HARDEN-004 step 5, narrowed by DEC-045 / REFAC-094 — what `sol cloud destroy`
   is justified in claiming happened.

   The governing rule stays: failure to obtain evidence is not evidence of the
   desired postcondition, and UNKNOWN is never read as ABSENT. What changed is
   *which* evidence the product owns. DEC-045 decided, from Terraform's and the
   providers' primary sources, that for resources Terraform is configured to
   delete, a successful `terraform destroy` plus an empty state is the authority
   for absence: Terraform removes an object from state only when the provider's
   delete returned success. So this module no longer re-queries every resource
   Terraform manages, and no longer models provider identity (ARNs, self-links,
   per-kind lookup recipes) -- that work belongs to qualification's independent
   inventory, not to every product destroy.

   Three legs remain, each for something Terraform's destroy cannot speak for:

   - **state**: a fresh read of this root's own state after destroy -- empty is
     the Terraform-side postcondition, residue is a violation, an unreadable read
     is UNKNOWN;
   - **sweep**: residue Terraform does not own (DEC-045 classes 1 and 4) --
     controller-created load balancers and PVC volumes, the abandoned
     service-networking peering;
   - **retention**: what a target promised to keep, or promised not to keep
     (DEC-033; DEC-045 class 3), observed from the provider.

   The module is pure: every process invocation is made by the caller, which
   hands in what it returned. *)

let contains ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec at i =
    if needle_length = 0
    then true
    else if i + needle_length > haystack_length
    then false
    else if String.sub haystack i needle_length = needle
    then true
    else at (i + 1)
  in
  at 0
;;

let abbreviate ?(limit = 400) text =
  let text = String.trim text in
  if String.length text <= limit then text else String.sub text 0 limit ^ "..."
;;

(* ── What running a provider query returned ────────────────────────────────── *)

type lookup_result =
  | Answered of
      { status : int
      ; stdout : string
      ; stderr : string
      }
  | Unavailable of string
(* The tool could not be run at all (absent from PATH, not executable,
         refused to start). Never absence: nothing was asked. *)

(* The name that follows a literal marker, lowercased text assumed. Used to read
   the *subject* out of a gcloud message. *)
let names_after ~marker text =
  let marker_length = String.length marker in
  let text_length = String.length text in
  let is_name_char c =
    (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.'
  in
  let rec scan i acc =
    if i + marker_length > text_length
    then acc
    else if String.sub text i marker_length = marker
    then (
      let start = i + marker_length in
      let rec take j =
        if j < text_length && is_name_char text.[j] then take (j + 1) else j
      in
      let stop = take start in
      let name = String.sub text start (stop - start) in
      scan (max (i + 1) stop) (if name = "" then acc else name :: acc))
    else scan (i + 1) acc
  in
  List.rev (scan 0 [])
;;

(* The project(s) a gcloud message names. Both shapes are real: the resource path
   (`projects/<p>/locations/...`) and the quoted subject (`The project '<p>' was
   not found`). *)
let gcp_mentioned_projects stderr =
  let text = String.lowercase_ascii stderr in
  names_after ~marker:"projects/" text @ names_after ~marker:"project '" text
;;

(* Finding C, closed. GCP answers 404 both for "the object is gone" and for "that
   project is not visible to you", so a not-found is evidence about the object we
   asked for *only when the answer's subject matches*: if the message names a
   project that is not the one this identity was captured in, the answer is about
   something else, and reading it as absence is exactly how a wrong lookup becomes
   a false postcondition. With no captured project to compare against there is
   nothing to contradict, so the wording stands.

   The wording list stays because gcloud publishes no structured result: Attempt 4
   found a 404 the old check could not recognise, and a check that cannot recognise
   absence makes Absent unreachable. *)
let gcp_absence_message ?project stderr =
  let text = String.lowercase_ascii stderr in
  let absent_wording =
    List.exists
      (fun needle -> contains ~needle text)
      [ "code=404"; "httperror 404"; "not_found"; "not found"; "does not exist" ]
  in
  let subject_matches =
    match project with
    | None -> true
    | Some project ->
      let project = String.lowercase_ascii project in
      List.for_all (fun mentioned -> mentioned = project) (gcp_mentioned_projects stderr)
  in
  absent_wording && subject_matches
;;

(* `An error occurred (Code) when calling the Operation operation: ...`. The code
   is what a caller is allowed to branch on; the prose around it is not. *)
let aws_error_code stderr =
  let open_ = String.index_opt stderr '(' in
  match open_ with
  | None -> None
  | Some open_ ->
    let close = String.index_from_opt stderr (open_ + 1) ')' in
    (match close with
     | Some close when close > open_ + 1 ->
       Some (String.sub stderr (open_ + 1) (close - open_ - 1))
     | _ -> None)
;;

type state_evidence =
  | State_absent (* the read succeeded and this root represents nothing *)
  | State_residue of string list (* the read succeeded and these addresses remain *)
  | State_unreadable of string (* the read failed, or the document was malformed *)

let state_evidence = function
  | Ok [] -> State_absent
  | Ok addresses -> State_residue addresses
  | Error reason -> State_unreadable reason
;;

(* ── Residue Terraform does not own ────────────────────────────────────────

   The provider checks that remain after DEC-045: objects Terraform does not
   manage and so cannot destroy -- load balancers the in-cluster cloud controller
   creates, volumes created for PersistentVolumeClaims, the service-networking
   peering the GCP root deliberately abandons. A residue is a violation; an
   indeterminate check is reported and never converted into absence. *)

type sweep =
  | Sweep_not_run
  | Sweep_ran of
      { residues : string list
        (* positive findings: something attributable to this target is still there *)
      ; indeterminate : string list
        (* checks that could not establish anything (a failed query, a cannot
             reconstruct the name): reported, never read as absence *)
      }

(* ── Retention, observed rather than printed ───────────────────────────────── *)

type retention =
  | Retention_required_and_observed of string
    (* the target declared a retention guarantee and the provider was observed
         to hold it *)
  | Retention_not_required of string
    (* there was no retention promise to observe, and why *)
  | Retention_violated of string
  | Retention_unknown of string

(* The retention evidence, classified and abbreviated -- for diagnostics and test
   failures rather than for the operator-facing report, which prints the sentence
   itself. *)
let retention_to_string = function
  | Retention_required_and_observed evidence -> "observed: " ^ evidence
  | Retention_not_required reason -> "not required: " ^ reason
  | Retention_violated reason -> "violated: " ^ reason
  | Retention_unknown reason -> "unknown: " ^ reason
;;

(* [Pending] is the provider saying "not yet": the snapshot exists and has not
   reached the state the retention contract requires. The caller keeps observing
   for a bounded time; it is never reported as success. *)
type retention_probe =
  | Settled of retention
  | Pending of string

(* The retention queries are stated here too, so "what was actually asked" is one
   readable thing per promise rather than a flag list assembled at the edge. *)
let final_snapshot_query ~snapshot_id ~region =
  [ "aws"
  ; "rds"
  ; "describe-db-snapshots"
  ; "--db-snapshot-identifier"
  ; snapshot_id
  ; "--region"
  ; region
  ; "--output"
  ; "json"
  ]
;;

let instance_snapshots_query ~instance ~region =
  [ "aws"
  ; "rds"
  ; "describe-db-snapshots"
  ; "--db-instance-identifier"
  ; instance
  ; "--region"
  ; region
  ; "--output"
  ; "json"
  ]
;;

(* `{"DBSnapshots":[{"DBSnapshotIdentifier":..,"SnapshotType":..,"Status":..}]}`. *)
let snapshots_of_json stdout =
  try
    match Yojson.Safe.from_string stdout with
    | `Assoc _ as document ->
      (match Yojson.Safe.Util.member "DBSnapshots" document with
       | `List items ->
         Ok
           (List.map
              (fun item ->
                 let open Yojson.Safe.Util in
                 ( member "DBSnapshotIdentifier" item |> to_string_option
                 , member "SnapshotType" item |> to_string_option
                 , member "Status" item |> to_string_option ))
              items)
       | _ -> Error "the provider's answer carries no `DBSnapshots` array")
    | _ -> Error "the provider's answer is not a JSON object"
  with
  | Yojson.Json_error message -> Error ("the provider's answer is not JSON: " ^ message)
  | Yojson.Safe.Util.Type_error (message, _) ->
    Error ("the provider's answer has an unexpected shape: " ^ message)
;;

let transient_snapshot_status = function
  | "creating" | "pending" | "starting" -> true
  | _ -> false
;;

let snapshot_label (id, kind, _) =
  Printf.sprintf
    "%s%s"
    (Option.value id ~default:"<unnamed>")
    (match kind with
     | Some kind -> " (" ^ kind ^ ")"
     | None -> "")
;;

(* The promised final snapshot must exist *and* reach the state the retention
   contract requires -- `available`, not merely "a record exists". The identifier
   is the one established before destroy; a provider answer about a different
   identifier is not evidence about this one. *)
let classify_final_snapshot ~declared ~snapshot_id lookup =
  let policy = Sol_cli_cloud_lifecycle.destroy_retention_to_string declared in
  match lookup with
  | Unavailable reason ->
    Settled
      (Retention_unknown
         (Printf.sprintf "final snapshot %s could not be queried: %s" snapshot_id reason))
  | Answered { status = 0; stdout; _ } ->
    (match snapshots_of_json stdout with
     | Error message ->
       Settled
         (Retention_unknown
            (Printf.sprintf
               "the provider's record for final snapshot %s could not be read: %s"
               snapshot_id
               message))
     | Ok snapshots ->
       (match List.find_opt (fun (id, _, _) -> id = Some snapshot_id) snapshots with
        | None ->
          Settled
            (Retention_violated
               (Printf.sprintf
                  "final-snapshot NOT observed (destroy_retention = %s): the provider's \
                   answer contains no snapshot %s%s"
                  policy
                  snapshot_id
                  (match snapshots with
                   | [] -> ""
                   | _ ->
                     " (it reported "
                     ^ String.concat ", " (List.map snapshot_label snapshots)
                     ^ ")")))
        | Some (_, _, Some "available") ->
          Settled
            (Retention_required_and_observed
               (Printf.sprintf
                  "final snapshot %s observed available (destroy_retention = %s, so the \
                   target outlives its compute; remove it with `aws rds \
                   delete-db-snapshot --db-snapshot-identifier %s` once it is no longer \
                   needed)"
                  snapshot_id
                  policy
                  snapshot_id))
        | Some (_, _, Some status) when transient_snapshot_status status ->
          Pending
            (Printf.sprintf
               "final snapshot %s exists and the provider reports it %s"
               snapshot_id
               status)
        | Some (_, _, Some status) ->
          Settled
            (Retention_violated
               (Printf.sprintf
                  "final-snapshot NOT observed (destroy_retention = %s): the provider \
                   reports snapshot %s as %s, which is not available"
                  policy
                  snapshot_id
                  status))
        | Some (_, _, None) ->
          Settled
            (Retention_unknown
               (Printf.sprintf
                  "the provider's record for final snapshot %s carries no status, so \
                   availability is not established"
                  snapshot_id))))
  | Answered { status; stderr; _ } ->
    (match aws_error_code stderr with
     | Some "DBSnapshotNotFound" ->
       Settled
         (Retention_violated
            (Printf.sprintf
               "final-snapshot NOT observed (destroy_retention = %s): the target \
                declared it keeps its final snapshot, and the provider explicitly \
                reports that %s does not exist"
               policy
               snapshot_id))
     | Some code ->
       Settled
         (Retention_unknown
            (Printf.sprintf
               "the final snapshot query failed (%s, exit %d), so the retention \
                guarantee is not established: %s"
               code
               status
               (abbreviate stderr)))
     | None ->
       Settled
         (Retention_unknown
            (Printf.sprintf
               "the final snapshot query failed with exit %d and no provider error code, \
                so the retention guarantee is not established: %s"
               status
               (abbreviate stderr))))
;;

(* Retain-nothing: no manual or automated snapshot attributable to this
   destruction may remain. The query is scoped by the *captured* database
   instance identifier -- the identity from the destruction transaction -- rather
   than by a broad name prefix, which is exactly the ambiguity to avoid. AWS
   documents that omitting `--snapshot-type` returns automated and manual
   snapshots (not shared/public/AWS-Backup ones), and that is what is checked. *)
let classify_instance_snapshots lookup =
  match lookup with
  | Unavailable reason ->
    Retention_unknown
      (Printf.sprintf
         "no-residue could not be observed: the snapshot query could not be run: %s"
         reason)
  | Answered { status = 0; stdout; _ } ->
    (match snapshots_of_json stdout with
     | Error message ->
       Retention_unknown
         (Printf.sprintf
            "no-residue could not be observed: the provider's answer could not be read: \
             %s"
            message)
     | Ok [] ->
       Retention_required_and_observed
         "none observed (destroy_retention = none): the provider returns no manual or \
          automated snapshot for this target's database"
     | Ok snapshots ->
       Retention_violated
         (Printf.sprintf
            "retain-nothing NOT observed (destroy_retention = none): %d snapshot(s) \
             attributable to this destruction remain: %s"
            (List.length snapshots)
            (String.concat ", " (List.map snapshot_label snapshots))))
  | Answered { status; stderr; _ } ->
    (match aws_error_code stderr with
     | Some ("DBInstanceNotFound" | "InvalidDBInstanceId.NotFound") ->
       Retention_required_and_observed
         "none observed (destroy_retention = none): the provider reports no such \
          database instance, so no snapshot of it is retained"
     | Some code ->
       Retention_unknown
         (Printf.sprintf
            "no-residue could not be observed: the snapshot query failed (%s, exit %d): \
             %s"
            code
            status
            (abbreviate stderr))
     | None ->
       Retention_unknown
         (Printf.sprintf
            "no-residue could not be observed: the snapshot query failed with exit %d \
             and no provider error code: %s"
            status
            (abbreviate stderr)))
;;

(* ── Combining the evidence, without voting ──────────────────────────────────

   Every source keeps its own voice. [violations] are postconditions with
   positive evidence against them; [unknowns] are required observations that could
   not be obtained. Both are failure ([is_verified] demands both be empty), but
   they are *not* the same claim, and neither is a degraded success: a degraded
   success means "the primary destruction postcondition succeeded but a
   preparation degraded", and an unestablished postcondition is not that. *)

type observation =
  { state : state_evidence
  ; sweep : sweep
  ; retention : retention
  }

type verdict =
  { violations : string list
  ; unknowns : string list
  }

let is_verified verdict = verdict.violations = [] && verdict.unknowns = []

let verdict_message verdict =
  let join = String.concat "; " in
  match verdict.violations, verdict.unknowns with
  | [], [] -> "the destruction postcondition is established"
  | violations, [] ->
    Printf.sprintf "the destruction postcondition is violated: %s" (join violations)
  | [], unknowns ->
    Printf.sprintf
      "the destruction postcondition could not be established (UNKNOWN is not absence): \
       %s"
      (join unknowns)
  | violations, unknowns ->
    Printf.sprintf
      "the destruction postcondition is violated (%s), and could not be established for \
       (%s)"
      (join violations)
      (join unknowns)
;;

let classify observation =
  let violations = ref [] in
  let unknowns = ref [] in
  let violate message = violations := message :: !violations in
  let unknown message = unknowns := message :: !unknowns in
  (match observation.state with
   | State_absent -> ()
   | State_residue addresses ->
     List.iter
       (fun address ->
          violate
            (Printf.sprintf
               "Terraform still represents %s in this root's state after destroy"
               address))
       addresses
   | State_unreadable reason ->
     unknown
       (Printf.sprintf
          "this root's Terraform state could not be read after destroy (%s), so what it \
           still represents is unknown"
          reason));
  (* Only a sweep's *residues* are violations. Its indeterminate checks are reported
     by [report] and are deliberately not promoted here: an unestablished query
     must not decide the result either way. *)
  (match observation.sweep with
   | Sweep_not_run -> ()
   | Sweep_ran { residues; _ } -> List.iter violate residues);
  (match observation.retention with
   | Retention_required_and_observed _ | Retention_not_required _ -> ()
   | Retention_violated reason -> violate reason
   | Retention_unknown reason -> unknown reason);
  { violations = List.rev !violations; unknowns = List.rev !unknowns }
;;

(* ── Operator-facing diagnostics ───────────────────────────────────────────── *)

let report observation =
  let buffer = Buffer.create 1024 in
  let line format = Printf.ksprintf (Buffer.add_string buffer) format in
  line "  verification: evidence, not `terraform destroy`'s exit status\n";
  (match observation.state with
   | State_absent ->
     line
       "    terraform state (disposable root): empty -- Terraform destroyed every \
        resource it manages (DEC-045: Terraform's destroy is the authority for them)\n"
   | State_residue addresses ->
     line
       "    terraform state (disposable root): STILL REPRESENTS %s\n"
       (String.concat ", " addresses)
   | State_unreadable reason ->
     line
       "    terraform state (disposable root): UNKNOWN -- the read failed (%s), which is \
        not absence\n"
       reason);
  (match observation.sweep with
   | Sweep_not_run -> ()
   | Sweep_ran { residues = []; indeterminate = [] } ->
     line
       "    residue Terraform does not own (controller load balancers, PVC volumes, \
        abandoned peering): none found\n"
   | Sweep_ran { residues; indeterminate } ->
     List.iter (fun reason -> line "    residue: %s\n" reason) residues;
     List.iter
       (fun reason ->
          line
            "    residue check inconclusive -- %s (reported, never read as absence)\n"
            reason)
       indeterminate);
  (match observation.retention with
   | Retention_required_and_observed evidence -> line "    retention: %s\n" evidence
   | Retention_not_required reason -> line "    retention: %s\n" reason
   | Retention_violated reason -> line "    retention: %s\n" reason
   | Retention_unknown reason -> line "    retention: %s\n" reason);
  Buffer.contents buffer
;;
