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
