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
  | Preparation_failed of string
  | Reconciliation_failed of string
  | Platform_destroy_failed of string
  | Substrate_destroy_failed of string
  | Verification_failed of string
  | Elevated_access_not_removed of string

type outcome =
  | Destroy_succeeded of
      { preparation : preparation
      ; substrate : substrate_presence
      ; cleanup : cleanup
      }
  | Destroy_failed of
      { failure : failure
      ; cleanup : cleanup
      }

let failure_message = function
  | Credentials_failed message -> message
  | Init_failed message -> message
  | Preparation_refused message -> message
  | Preparation_failed message -> message
  | Reconciliation_failed message -> message
  | Platform_destroy_failed message -> message
  | Substrate_destroy_failed message -> message
  | Verification_failed message -> message
  | Elevated_access_not_removed message -> message
;;

let exit_code = function
  | Destroy_succeeded _ -> 0
  | Destroy_failed _ -> 1
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
  ; prepare : state:state_read -> (preparation, string) result
  ; reconcile_and_enable : unit -> (unit, string) result
  ; destroy_platform : unit -> (unit, string) result
  ; remove_elevated_access : unit -> (unit, string) result
  ; observe_window_before : unit -> (unit, string) result
  ; verify_window_after : unit -> (unit, string) result
  ; destroy_substrate : unit -> (unit, string) result
  ; verify_absent : unit -> (unit, string) result
  ; report : string -> unit (* operator-facing progress, stdout *)
  ; warn : string -> unit (* operator-facing warning, stderr *)
  }

(* The structural bracket FND-0047 asked for: enable the elevated access, run the
   one operation that uses it, and remove the access **unconditionally** -- on
   success, on failure, and when enabling itself failed (the access may be
   half-open). The removal's result is returned, not lost. *)
let with_elevated_access ~deps =
  let enabled = deps.reconcile_and_enable () in
  let operation =
    match enabled with
    | Error message -> Error (`Reconciliation message)
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
       | Error message -> Error (`Platform message)
       | Ok () -> Ok ())
  in
  let removal = deps.remove_elevated_access () in
  let cleanup =
    match removal with
    | Ok () -> Cleanup_succeeded
    | Error message -> Cleanup_failed message
  in
  operation, cleanup
;;

let teardown ~deps ~substrate =
  match substrate with
  | Substrate_absent ->
    (* Terraform represents nothing. There is no substrate to reconcile or tear
       down at the platform layer; the substrate destroy below is still run,
       because it is idempotent and it is the only path that could remove
       something Terraform no longer tracks. *)
    Ok Cleanup_not_needed
  | Substrate_unknown ->
    (* The state could not be read, so it is NOT known to be empty. A whole-root
       constructive apply is exactly what must not run on an unreadable state,
       but destruction itself proceeds and the unknown-ness is reported rather
       than read as absence. *)
    Ok Cleanup_not_needed
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
       Ok Cleanup_not_needed
     | Outputs_available ->
       let operation, cleanup = with_elevated_access ~deps in
       (match cleanup with
        | Cleanup_succeeded ->
          (match deps.verify_window_after () with
           | Ok () -> ()
           | Error message -> deps.warn ("warning: " ^ message))
        | Cleanup_not_needed | Cleanup_failed _ -> ());
       (match operation with
        | Ok () -> Ok cleanup
        | Error (`Reconciliation message) -> Error (Reconciliation_failed message, cleanup)
        | Error (`Platform message) -> Error (Platform_destroy_failed message, cleanup)))
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
  let succeed ?(cleanup = Cleanup_not_needed) preparation =
    Destroy_succeeded { preparation; substrate; cleanup }
  in
  let fail ?(cleanup = Cleanup_not_needed) failure =
    Destroy_failed { failure; cleanup }
  in
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
         let preparation_result =
           match substrate with
           | Substrate_absent ->
             deps.report "  prepare: cloud substrate is absent, nothing to prepare.";
             Ok Nothing_prepared
           | Substrate_present | Substrate_unknown -> deps.prepare ~state
         in
         match preparation_result with
         | Error message -> fail (Preparation_failed message)
         | Ok preparation ->
           (match teardown ~deps ~substrate with
            | Error (failure, cleanup) -> fail ~cleanup failure
            | Ok cleanup ->
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
