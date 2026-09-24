(* The destroy execution core (HARDEN-004 step 2; REFAC-091).

   Two things live here, and they are deliberately separate:

   - a **typed inventory** of what Terraform's state representation actually
     owns, built from ONE `terraform show -json` observation. Resource identity
     comes from the real Terraform *address* (root module and child modules
     alike), not from a resource type mapped back onto a fixed address, and not
     from the install-time output contract. A state that cannot be read is
     [State_unreadable] -- UNKNOWN, which is not absence.

   - the destroy **execution core**: a result-returning sequence with every
     terraform/gcloud/aws operation injected through [deps]. It never calls
     [exit]; the command edge maps an [outcome] to a process exit code. The
     elevated bootstrap access is opened and removed around the one operation
     that uses it, so cleanup cannot be forgotten by a failing branch -- the
     shape FND-0047 found a hole in.

   The rollback lifecycle (`Sol_cli_rollback.execute`) is the repository
   precedent for both: a typed core, deps for the touchy operations, and the
   process exit owned by the caller. *)

type resource =
  { address : string
    (* The real Terraform address, e.g.
       ["module.net.google_compute_network.vpc"]. Preserved verbatim, including
       the module prefix, because it is what `-target=` and `state rm` address. *)
  ; kind : string (* The provider resource type, e.g. ["google_container_cluster"]. *)
  ; provider_id : string option
    (* The provider's own identity: [`self_link`] where the provider publishes
       one, otherwise [`id`]. *)
  ; project : string option (* GCP project, or the AWS account id. *)
  ; region : string option (* Region or location; a bare zone is reduced to its region. *)
  ; deletion_protection : bool option
    (* The provider's deletion guard where the resource declares one. [None] is
       "this resource has no such attribute" -- a benign null, never an error. *)
  ; final_snapshot_identifier : string option
  ; skip_final_snapshot : bool option
    (* The retention-relevant state the existing AWS preparation reads. GCP has
       no equivalent, so both are [None] there. *)
  }

type state_read =
  | State_empty
    (* The read succeeded and the state representation owns nothing. A valid,
       empty answer -- a half-built or never-built target, not a failure. *)
  | State_represented of resource list
    (* The read succeeded and these resources are represented. Non-empty by
       construction; the smart constructor folds [State_represented []] into
       [State_empty]. *)
  | State_unreadable of string
(* The read failed, or the representation is malformed. UNKNOWN. It is never
       absence, and no decision may read it as "the substrate is gone". *)

(* Whether Terraform currently represents a substrate, three-valued on purpose:
   folding [State_unreadable] into "absent" is the fail-open this type exists to
   prevent. *)
type substrate_presence =
  | Substrate_present
  | Substrate_absent
  | Substrate_unknown

let ( let* ) = Result.bind

let region_of_zone zone =
  match String.rindex_opt zone '-' with
  | Some i when i > 0 -> String.sub zone 0 i
  | _ -> zone
;;

let string_attr name values =
  match Yojson.Safe.Util.member name values with
  | `String s when s <> "" -> Some s
  | _ -> None
;;

let bool_attr name values =
  match Yojson.Safe.Util.member name values with
  | `Bool b -> Ok (Some b)
  | `Null -> Ok None
  | _ -> Error (Printf.sprintf "attribute %s is not a boolean" name)
;;

let region_of_values values =
  match string_attr "region" values with
  | Some _ as region -> region
  | None ->
    (match string_attr "location" values with
     | Some _ as location -> location
     | None -> Option.map region_of_zone (string_attr "zone" values))
;;

let resource_of_json json =
  let open Yojson.Safe.Util in
  let address = member "address" json |> to_string_option in
  let kind = member "type" json |> to_string_option in
  match address, kind with
  | Some address, Some kind ->
    let values = member "values" json in
    let* deletion_protection = bool_attr "deletion_protection" values in
    let* skip_final_snapshot = bool_attr "skip_final_snapshot" values in
    Ok
      { address
      ; kind
      ; provider_id =
          (match string_attr "self_link" values with
           | Some _ as self_link -> self_link
           | None -> string_attr "id" values)
      ; project =
          (match string_attr "project" values with
           | Some _ as project -> project
           | None -> string_attr "account_id" values)
      ; region = region_of_values values
      ; deletion_protection
      ; final_snapshot_identifier = string_attr "final_snapshot_identifier" values
      ; skip_final_snapshot
      }
  | None, _ ->
    Error
      "a resource in the state representation has no `address`, so its identity is \
       unknown"
  | _, None -> Error "a resource in the state representation has no `type`"
;;

(* Walk a Terraform module and every child module it contains, so a resource
   declared and represented inside a child module keeps its real address rather
   than disappearing because only the root module was searched (FND-0048). *)
let rec resources_of_module json : (resource list, string) result =
  let open Yojson.Safe.Util in
  let* own =
    match member "resources" json with
    | `Null -> Ok []
    | `List items ->
      List.fold_left
        (fun acc item ->
           let* acc = acc in
           let* resource = resource_of_json item in
           Ok (resource :: acc))
        (Ok [])
        items
      |> Result.map List.rev
    | _ -> Error "a module's `resources` is not a list"
  in
  let* children =
    match member "child_modules" json with
    | `Null -> Ok []
    | `List items ->
      List.fold_left
        (fun acc item ->
           let* acc = acc in
           let* child = resources_of_module item in
           Ok (List.rev_append child acc))
        (Ok [])
        items
      |> Result.map List.rev
    | _ -> Error "a module's `child_modules` is not a list"
  in
  Ok (own @ children)
;;

(* The one state observation, classified. [State_empty] is a valid absence; a
   missing `values` is that (FND-0048), not a failure. Anything the parser cannot
   make sense of is [State_unreadable] -- UNKNOWN. *)
let inventory_of_show_json json =
  try
    let document = Yojson.Safe.from_string json in
    let open Yojson.Safe.Util in
    match member "values" document with
    | `Null -> State_empty
    | `Assoc _ as values ->
      (match member "root_module" values with
       | `Null -> State_empty
       | root_module ->
         (match resources_of_module root_module with
          | Ok [] -> State_empty
          | Ok resources -> State_represented resources
          | Error message -> State_unreadable message))
    | _ ->
      State_unreadable "unexpected `terraform show -json` shape: values is not an object"
  with
  | Yojson.Json_error message ->
    State_unreadable ("invalid `terraform show -json`: " ^ message)
  | Yojson.Safe.Util.Type_error (message, _) ->
    State_unreadable ("unexpected `terraform show -json` shape: " ^ message)
;;

let resources = function
  | State_represented resources -> resources
  | State_empty | State_unreadable _ -> []
;;

let addresses state = List.map (fun resource -> resource.address) (resources state)

let substrate_presence = function
  | State_represented _ -> Substrate_present
  | State_empty -> Substrate_absent
  | State_unreadable _ -> Substrate_unknown
;;

let find_address state address =
  List.find_opt (fun resource -> resource.address = address) (resources state)
;;

(* What destruction preparation did, carried so the command edge can report what
   survived by identifier. Kept provider-shaped because the difference is real:
   AWS's final snapshot has no GCP counterpart (DEC-033). *)
type preparation =
  | Nothing_prepared
  | Aws_prepared of string
  | Gcp_prepared

(* The outcome of the elevated bootstrap-access window. A failure to remove it is
   evidence, never silently swallowed, and never replaced by an unrelated
   success. *)
type cleanup =
  | Cleanup_not_needed
  | Cleanup_succeeded
  | Cleanup_failed of string

(* Whether the install-time outputs could be read. The library decides from the
   inventory, so this only says whether the platform teardown can be *wired* --
   it is never what decides whether the target exists (FND-0044 point 2). *)
type outputs_read =
  | Outputs_available
  | Outputs_unavailable of string

type failure =
  | Credentials_failed of string
  | Init_failed of string
  | Preparation_refused of string
  | Platform_destroy_failed of string
  | Substrate_destroy_failed of string
  | Verification_failed of string
  | Elevated_access_not_removed of string

(* What the destruction ultimately did. A preparation's *consequence* is structural
   here rather than flattened into a bool:

   - [Destroy_succeeded] with no [degradations] is the clean history: every
     applicable preparation succeeded or had nothing to do, destruction reached
     absence, and verification confirmed it.
   - [Destroy_succeeded] with [degradations] is a *different* history: a
     [Continue_to_destroy] preparation failed or its plan was refused, destruction
     proceeded anyway, and absence was still reached. Both end at absence; they are
     not the same run, and the exit code says so (HARDEN-004 step 4).
   - [Destroy_blocked] means a [Block_destroy] preparation failed, so destruction
     did not run: proceeding would have violated an explicit destruction-time
     guarantee the target declared (DEC-033). The guarantee is named. There is no
     cleanup to report -- a block happens before the elevated-access bracket is ever
     entered -- so the outcome carries none.
   - [Destroy_failed] means destruction did not reach its postcondition. It carries
     [degradations] too, so "a preparation failed and then the destroy failed"
     cannot collapse into one fact -- and a cleanup failure is evidence alongside
     the primary failure, never a replacement for it. *)
type outcome =
  | Destroy_succeeded of
      { preparation : preparation
      ; degradations : string list
      ; substrate : substrate_presence
      ; cleanup : cleanup
      }
  | Destroy_blocked of { guarantee : string }
  | Destroy_failed of
      { failure : failure
      ; degradations : string list
      ; cleanup : cleanup
      }

let failure_message = function
  | Credentials_failed message -> message
  | Init_failed message -> message
  | Preparation_refused message -> message
  | Platform_destroy_failed message -> message
  | Substrate_destroy_failed message -> message
  | Verification_failed message -> message
  | Elevated_access_not_removed message -> message
;;

(* The exit-code contract, decided by the operator for HARDEN-004 step 4: [0] only
   when every applicable preparation succeeded or had nothing to do *and* the
   destroy reached and verified absence; [3] when it reached absence with a
   [Continue_to_destroy] preparation degraded; [1] for a failed or blocked destroy.
   [2] stays reserved for this CLI's refusal / cannot-proceed-as-requested
   semantics, so it is deliberately not used here. *)
let exit_clean = 0
let exit_degraded = 3
let exit_failure = 1

let exit_code = function
  | Destroy_succeeded { degradations = []; _ } -> exit_clean
  | Destroy_succeeded { degradations = _ :: _; _ } -> exit_degraded
  | Destroy_blocked _ | Destroy_failed _ -> exit_failure
;;

(* Every operation the sequence performs, injected. The concrete provider calls
   (terraform, gcloud, aws) live behind these; what is left here is ordering,
   the inventory-derived decisions, and the cleanup bracket -- all executable
   offline against fakes (HARDEN-004 step 2's test contract). *)
type deps =
  { require_credentials : unit -> (unit, string) result
  ; terraform_init : unit -> (unit, string) result
  ; observe_state : unit -> (string, string) result
    (* [Ok stdout] of `terraform show -json`, or [Error detail] when the read
       itself failed. The classification into the typed inventory is below, so a
       process failure is exercised the same way as a malformed document. *)
  ; cloud_outputs : unit -> outputs_read
  ; prepare : state:state_read -> preparation Sol_cli_cloud_lifecycle.preparation_outcome
    (* The preparation declares the consequence of its own failure (DEC-033), so
       this is not a [result]: a failure that permits destruction is a
       [Preparation_failed] the sequence records and continues past, and only a
       [Block_destroy] one stops it. *)
  ; reconcile_and_enable : unit -> (unit, string) result
    (* Obtain the bootstrap authority, and reconcile the guarded resources, in one
       asserted apply. Its failure has one consequence the type can already
       express honestly: no authority, so the operation the window exists to
       authorise cannot run. It is *not* two responsibilities needing two
       dependency shapes -- both halves of that apply share the fate of the plan,
       and the protected operation is skipped either way, reported as a
       degradation while the substrate destroy proceeds. *)
  ; destroy_platform : unit -> (unit, string) result
  ; remove_elevated_access : unit -> (unit, string) result
  ; observe_window_before : unit -> (unit, string) result
  ; verify_window_after : unit -> (unit, string) result
  ; destroy_substrate : unit -> (unit, string) result
  ; verify_absent : unit -> (unit, string) result
  ; report : string -> unit (* operator-facing progress, stdout *)
  ; warn : string -> unit (* operator-facing warning, stderr *)
  }

(* What became of the operation the bootstrap window exists to authorise. Its two
   failure modes are not interchangeable: [Protected_skipped] means the authority
   could not be obtained, so the protected operation could not run -- a degradation
   of this destroy, because the substrate destroy needs no cluster authority;
   [Protected_failed] means it ran and failed -- a failure of this destroy.
   Collapsing them is exactly how "we lack the authority required" would become
   "we chose not to run it". *)
type protected_operation =
  | Protected_ran
  | Protected_skipped of string
  | Protected_failed of string

(* The structural bracket FND-0047 asked for: enable the elevated access, run the
   one operation that uses it, and remove the access **unconditionally** -- on
   success, on failure, and when enabling itself failed (the access may be
   half-open). The removal's result is returned, not lost. *)
let with_elevated_access ~deps =
  let operation =
    match deps.reconcile_and_enable () with
    | Error message -> Protected_skipped message
    | Ok () ->
      (match deps.observe_window_before () with
       | Ok () -> ()
       | Error message ->
         deps.warn
           (Printf.sprintf
              "warning: the bootstrap window could not be observed before teardown (%s); \
               its effective removal will not be verified. Teardown removes the access \
               with the substrate anyway."
              message));
      (match deps.destroy_platform () with
       | Error message -> Protected_failed message
       | Ok () -> Protected_ran)
  in
  let removal = deps.remove_elevated_access () in
  let cleanup =
    match removal with
    | Ok () -> Cleanup_succeeded
    | Error message -> Cleanup_failed message
  in
  operation, cleanup
;;

(* The platform teardown, and the degradations it contributes. A preparation that
   failed but permits destruction comes back as evidence rather than as a failure,
   so a refused reconciliation narrows what this destroy could do without refusing
   the destroy: the substrate destroy below needs no cluster authority, and
   stranding a target is the failure mode this whole path exists to remove. *)
let teardown ~deps ~substrate : (cleanup * string list, failure * cleanup) result =
  match substrate with
  | Substrate_absent ->
    (* Terraform represents nothing. There is no substrate to reconcile or tear
       down at the platform layer; the substrate destroy below is still run,
       because it is idempotent and it is the only path that could remove
       something Terraform no longer tracks. *)
    Ok (Cleanup_not_needed, [])
  | Substrate_unknown ->
    (* The state could not be read, so it is NOT known to be empty. A whole-root
       constructive apply is exactly what must not run on an unreadable state,
       but destruction itself proceeds and the unknown-ness is reported rather
       than read as absence. *)
    Ok (Cleanup_not_needed, [])
  | Substrate_present ->
    (match deps.cloud_outputs () with
     | Outputs_unavailable reason ->
       (* FND-0044 point 2: a half-built target may have no outputs, partial
          outputs, or complete outputs, and none of those decide whether
          destruction is available. The platform teardown cannot be *wired*
          without them, so it is skipped and said out loud -- not refused. *)
       deps.warn
         (Printf.sprintf
            "warning: the install outputs are unavailable (%s), so the platform teardown \
             cannot be wired and is skipped. What Terraform represents is still \
             destroyed, and this is not a refusal."
            reason);
       Ok (Cleanup_not_needed, [])
     | Outputs_available ->
       let operation, cleanup = with_elevated_access ~deps in
       (match cleanup with
        | Cleanup_succeeded ->
          (match deps.verify_window_after () with
           | Ok () -> ()
           | Error message -> deps.warn ("warning: " ^ message))
        | Cleanup_not_needed | Cleanup_failed _ -> ());
       (match operation with
        | Protected_ran -> Ok (cleanup, [])
        | Protected_skipped message ->
          Ok
            ( cleanup
            , [ Printf.sprintf
                  "the platform teardown was skipped because the bootstrap authority it \
                   needs could not be obtained (%s)"
                  message
              ] )
        | Protected_failed message -> Error (Platform_destroy_failed message, cleanup)))
;;

let execute ~deps =
  let state =
    match deps.observe_state () with
    | Ok stdout -> inventory_of_show_json stdout
    | Error detail -> State_unreadable detail
  in
  let substrate = substrate_presence state in
  (match state with
   | State_unreadable reason ->
     deps.warn
       (Printf.sprintf
          "warning: could not read this target's Terraform state (%s); what it \
           represents is unknown, which is not the same as absent. Destruction proceeds; \
           this is not evidence the substrate is gone."
          reason)
   | State_empty | State_represented _ -> ());
  (* A preparation that failed but permits destruction is evidence, not silence:
     the outcome must never read the same as a clean destroy, and the exit code
     depends on this list being non-empty (HARDEN-004 step 4). *)
  let degradations = ref [] in
  let degrade what reason =
    let message = Printf.sprintf "%s: %s" what reason in
    deps.warn ("warning: " ^ message);
    degradations := message :: !degradations
  in
  let succeed ?(cleanup = Cleanup_not_needed) preparation =
    Destroy_succeeded
      { preparation; degradations = List.rev !degradations; substrate; cleanup }
  in
  let fail ?(cleanup = Cleanup_not_needed) failure =
    Destroy_failed { failure; degradations = List.rev !degradations; cleanup }
  in
  let block guarantee = Destroy_blocked { guarantee } in
  match deps.require_credentials () with
  | Error message -> fail (Credentials_failed message)
  | Ok () ->
    (match deps.terraform_init () with
     | Error message -> fail (Init_failed message)
     | Ok () ->
       (* B / FND-0044 point 2: substrate existence comes from what Terraform
          represents, never from the install-time output contract. *)
       let cloud_exists = substrate <> Substrate_absent in
       let phase =
         Sol_cli_cloud_lifecycle.enter_destruction
           ~from:
             (Sol_cli_cloud_lifecycle.observed_phase
                ~cloud_exists
                ~platform_installed:true)
       in
       deps.report
         (Printf.sprintf
            "  lifecycle phase: %s"
            (Sol_cli_cloud_lifecycle.phase_to_string phase));
       if Sol_cli_cloud_lifecycle.ready_policy_applies phase
       then
         fail
           (Preparation_refused
              "Ready policy must not apply once destruction has been prepared")
       else (
         (* An empty inventory has nothing to prepare: no guarded resource, no
            database. This is the valid-absence case, decided from state rather
            than from install outputs. UNKNOWN and PRESENT both go to the provider
            preparation, so a read that merely failed is never read as empty. *)
         let preparation_outcome =
           match substrate with
           | Substrate_absent ->
             deps.report "  prepare: cloud substrate is absent, nothing to prepare.";
             Sol_cli_cloud_lifecycle.Nothing_to_prepare
           | Substrate_present | Substrate_unknown -> deps.prepare ~state
         in
         (* The preparation declares the consequence of its own failure (DEC-033):
            only [Block_destroy] stops destruction, and it names the guarantee the
            target declared. Everything else is a degradation the run carries. *)
         match Sol_cli_cloud_lifecycle.destruction_blocked preparation_outcome with
         | Some guarantee -> block guarantee
         | None ->
           (match Sol_cli_cloud_lifecycle.preparation_failure preparation_outcome with
            | Some reason -> degrade "preparation" reason
            | None -> ());
           let preparation =
             match preparation_outcome with
             | Sol_cli_cloud_lifecycle.Prepared preparation -> preparation
             | Sol_cli_cloud_lifecycle.Nothing_to_prepare
             | Sol_cli_cloud_lifecycle.Preparation_failed _ -> Nothing_prepared
           in
           (match teardown ~deps ~substrate with
            | Error (failure, cleanup) -> fail ~cleanup failure
            | Ok (cleanup, teardown_degradations) ->
              List.iter
                (fun message -> degradations := message :: !degradations)
                teardown_degradations;
              (* A removal failure on the otherwise-successful path is fatal, the
                 same as the old `require_terraform_success (deescalate ())`; it
                 is carried as the failure rather than dropped. *)
              (match cleanup with
               | Cleanup_failed message ->
                 fail ~cleanup (Elevated_access_not_removed message)
               | Cleanup_not_needed | Cleanup_succeeded ->
                 if cloud_exists
                 then
                   deps.report
                     (Printf.sprintf
                        "  lifecycle phase: %s"
                        (Sol_cli_cloud_lifecycle.phase_to_string
                           Sol_cli_cloud_lifecycle.Destroying));
                 (match deps.destroy_substrate () with
                  | Error message -> fail ~cleanup (Substrate_destroy_failed message)
                  | Ok () ->
                    deps.report "\nVerifying teardown...";
                    (match deps.verify_absent () with
                     | Error message -> fail ~cleanup (Verification_failed message)
                     | Ok () -> succeed ~cleanup preparation))))))
;;

(* ── Phase allowlists for the destroy-path applies (HARDEN-004 step 3) ────────

   Every apply reachable from destroy is planned and classified against one of
   these before it runs (see [Sol_cli_terraform_plan.guarded_apply]). They are
   phase-specific on purpose: "reconciliation" and "cleanup" are names, not
   safety properties, and the bootstrap-access *removal* apply is asserted like
   any other.

   Each allowlist is stated in terms of Terraform addresses/actions. Nothing here
   permits a create or a replacement of target-owned infrastructure except the
   narrowly identified temporary bootstrap-access mechanism, whose creation is
   the point of the window and whose removal is bracketed by [execute]. *)

let guard_preparation_policy ~addresses : Sol_cli_terraform_plan.policy =
  let open Sol_cli_terraform_plan in
  { phase = "guard-preparation"
  ; rules =
      [ { matches = List.map (fun address -> Exact address) addresses
        ; allows = [ Update ]
        ; reason =
            "a guarded resource the inventory already represents may only have its \
             deletion protection lowered"
        }
      ]
  }
;;

let bootstrap_enable_policy ~bootstrap : Sol_cli_terraform_plan.policy =
  let open Sol_cli_terraform_plan in
  { phase = "bootstrap-access-enable"
  ; rules =
      [ { matches = bootstrap
        ; allows = [ Create; Update ]
        ; reason =
            "the temporary bootstrap-access mechanism may be created or updated to \
             obtain destruction authority"
        }
      ]
  }
;;

(* The reconciliation apply exists to hold the bootstrap window open while the
   destroy policy is in force. It may touch the bootstrap mechanism and reconcile
   the guarded resources the inventory represents -- nothing else. *)
let reconciliation_policy ~bootstrap ~guarded : Sol_cli_terraform_plan.policy =
  let open Sol_cli_terraform_plan in
  { phase = "destroy-reconciliation"
  ; rules =
      [ { matches = bootstrap
        ; allows = [ Create; Update ]
        ; reason =
            "the temporary bootstrap-access mechanism may be created or updated to \
             obtain destruction authority"
        }
      ; { matches = List.map (fun address -> Exact address) guarded
        ; allows = [ Update ]
        ; reason =
            "a guarded resource the inventory represents may only be reconciled to the \
             destroy policy"
        }
      ]
  }
;;

(* Removal only ever *removes* the elevation. Both providers express the closed
   window as the absence of the mechanism: GCP's
   `kubernetes_cluster_role_binding.provisioner_bootstrap_admin` has
   `count = var.provisioner_bootstrap_admin ? 1 : 0` (so [false] with an open
   window plans a delete, and with a closed one plans nothing), and AWS's
   `access_entries` map drops the `bootstrap` policy association when the variable
   is false (so the association is removed). No removal transition can require a
   create -- a create here would mean the apply is *adding* the elevation it was
   asked to close. Step 3 allowed it defensively; this tightens it, and
   `test_terraform_plan.ml` pins that a create of the mechanism is refused. *)
let bootstrap_removal_policy ~bootstrap : Sol_cli_terraform_plan.policy =
  let open Sol_cli_terraform_plan in
  { phase = "bootstrap-access-removal"
  ; rules =
      [ { matches = bootstrap
        ; allows = [ Update; Delete ]
        ; reason =
            "the temporary bootstrap-access mechanism may only be updated or removed"
        }
      ]
  }
;;
