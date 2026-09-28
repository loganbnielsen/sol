type resource =
  { address : string
  ; kind : string
  ; name : string option
  ; identifier : string option
  ; deletion_protection : bool option
  ; final_snapshot_identifier : string option
  ; skip_final_snapshot : bool option
  }

type state_read =
  | State_empty
  | State_represented of resource list
  | State_unreadable of string

type substrate_presence =
  | Substrate_present
  | Substrate_absent
  | Substrate_unknown

open Result.Syntax

let string_attr name values =
  match Sol_cli_json.field [ name ] values with
  | `String s when s <> "" -> Some s
  | _ -> None
;;

let bool_attr name values =
  match Sol_cli_json.field [ name ] values with
  | `Bool b -> Ok (Some b)
  | `Null -> Ok None
  | _ -> Error (Printf.sprintf "attribute %s is not a boolean" name)
;;

let resource_of_json json =
  let address = Sol_cli_json.field [ "address" ] json |> Sol_cli_json.string in
  let kind = Sol_cli_json.field [ "type" ] json |> Sol_cli_json.string in
  match address, kind with
  | Some address, Some kind ->
    let values = Sol_cli_json.field [ "values" ] json in
    let* deletion_protection = bool_attr "deletion_protection" values in
    let* skip_final_snapshot = bool_attr "skip_final_snapshot" values in
    Ok
      { address
      ; kind
      ; name = string_attr "name" values
      ; identifier = string_attr "identifier" values
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

let rec resources_of_module json : (resource list, string) result =
  let* own =
    match Sol_cli_json.field [ "resources" ] json with
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
    match Sol_cli_json.field [ "child_modules" ] json with
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

let inventory_of_show_json json =
  match Yojson.Safe.from_string json with
  | exception Yojson.Json_error message ->
    State_unreadable ("invalid `terraform show -json`: " ^ message)
  | document ->
    (match Sol_cli_json.field [ "values" ] document with
     | `Null -> State_empty
     | `Assoc _ as values ->
       (match Sol_cli_json.field [ "root_module" ] values with
        | `Null -> State_empty
        | root_module ->
          (match resources_of_module root_module with
           | Ok [] -> State_empty
           | Ok resources -> State_represented resources
           | Error message -> State_unreadable message))
     | _ ->
       State_unreadable "unexpected `terraform show -json` shape: values is not an object")
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

type preparation =
  | Nothing_prepared
  | Prepared of { retained : string option }

type cleanup =
  | Cleanup_not_needed
  | Cleanup_succeeded
  | Cleanup_failed of string

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

type outcome =
  | Destroy_succeeded of
      { preparation : preparation
      ; degradations : string list
      ; substrate : substrate_presence
      ; cleanup : cleanup
      ; verification : Sol_cli_destroy_verification.observation
      }
  | Destroy_blocked of { guarantee : string }
  | Destroy_failed of
      { failure : failure
      ; degradations : string list
      ; cleanup : cleanup
      ; verification : Sol_cli_destroy_verification.observation option
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

let exit_clean = 0
let exit_failure = 1

let exit_code = function
  | Destroy_succeeded _ -> exit_clean
  | Destroy_blocked _ | Destroy_failed _ -> exit_failure
;;

let completion_message = function
  | Destroy_succeeded { degradations = []; _ } ->
    "Done. Destruction reached verified absence."
  | Destroy_succeeded { degradations; _ } ->
    Printf.sprintf
      "Done, with %d degraded preparation(s). Destruction reached verified absence."
      (List.length degradations)
  | Destroy_blocked { guarantee } ->
    Printf.sprintf
      "Destruction is blocked by a guarantee this target declared, so nothing was \
       destroyed: %s"
      guarantee
  | Destroy_failed { failure; _ } ->
    Printf.sprintf
      "Destruction did not converge: %s. What remains is whatever the verification above \
       reports; nothing here establishes that the resources are gone."
      (failure_message failure)
;;

type deps =
  { require_credentials : unit -> (unit, string) result
  ; terraform_init : unit -> (unit, string) result
  ; observe_state : unit -> (string, string) result
  ; cloud_outputs : unit -> outputs_read
  ; prepare : state:state_read -> preparation Sol_cli_cloud_lifecycle.preparation_outcome
  ; reconcile_and_enable : unit -> (unit, string) result
  ; destroy_platform : unit -> (unit, string) result
  ; remove_elevated_access : unit -> (unit, string) result
  ; observe_window_before : unit -> (unit, string) result
  ; verify_window_after : unit -> (unit, string) result
  ; destroy_substrate : unit -> (unit, string) result
  ; verify_destruction :
      pre_destroy:state_read
      -> preparation:preparation
      -> Sol_cli_destroy_verification.observation
  ; report : string -> unit
  ; warn : string -> unit
  }

type protected_operation =
  | Protected_ran
  | Protected_skipped of string
  | Protected_failed of string

let with_elevated_access ~deps =
  let operation =
    match deps.reconcile_and_enable () with
    | Error message -> Protected_skipped message
    | Ok () ->
      deps.observe_window_before ()
      |> Result.iter_error (fun message ->
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

let teardown ~deps ~substrate : (cleanup * string list, failure * cleanup) result =
  match substrate with
  | Substrate_absent -> Ok (Cleanup_not_needed, [])
  | Substrate_unknown -> Ok (Cleanup_not_needed, [])
  | Substrate_present ->
    (match deps.cloud_outputs () with
     | Outputs_unavailable reason ->
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
          deps.verify_window_after ()
          |> Result.iter_error (fun message -> deps.warn ("warning: " ^ message))
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
  let degradations = ref [] in
  let degrade what reason =
    let message = Printf.sprintf "%s: %s" what reason in
    deps.warn ("warning: " ^ message);
    degradations := message :: !degradations
  in
  let succeed ?(cleanup = Cleanup_not_needed) ~verification preparation =
    Destroy_succeeded
      { preparation
      ; degradations = List.rev !degradations
      ; substrate
      ; cleanup
      ; verification
      }
  in
  let fail ?(cleanup = Cleanup_not_needed) ?verification failure =
    Destroy_failed
      { failure; degradations = List.rev !degradations; cleanup; verification }
  in
  let block guarantee = Destroy_blocked { guarantee } in
  let destroy_and_verify ~cloud_exists ~cleanup ~preparation =
    if cloud_exists
    then
      deps.report
        (Printf.sprintf
           "  lifecycle phase: %s"
           (Sol_cli_cloud_lifecycle.phase_to_string Sol_cli_cloud_lifecycle.Destroying));
    match deps.destroy_substrate () with
    | Error message -> fail ~cleanup (Substrate_destroy_failed message)
    | Ok () ->
      deps.report "\nVerifying teardown...";
      let observation = deps.verify_destruction ~pre_destroy:state ~preparation in
      let verdict = Sol_cli_destroy_verification.classify observation in
      if Sol_cli_destroy_verification.is_verified verdict
      then succeed ~cleanup ~verification:observation preparation
      else
        fail
          ~cleanup
          ~verification:observation
          (Verification_failed (Sol_cli_destroy_verification.verdict_message verdict))
  in
  match deps.require_credentials () with
  | Error message -> fail (Credentials_failed message)
  | Ok () ->
    (match deps.terraform_init () with
     | Error message -> fail (Init_failed message)
     | Ok () ->
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
         let preparation_outcome =
           match substrate with
           | Substrate_absent ->
             deps.report "  prepare: cloud substrate is absent, nothing to prepare.";
             Sol_cli_cloud_lifecycle.Nothing_to_prepare
           | Substrate_present | Substrate_unknown -> deps.prepare ~state
         in
         match Sol_cli_cloud_lifecycle.destruction_blocked preparation_outcome with
         | Some guarantee -> block guarantee
         | None ->
           Sol_cli_cloud_lifecycle.preparation_failure preparation_outcome
           |> Option.iter (fun reason -> degrade "preparation" reason);
           let preparation =
             match preparation_outcome with
             | Sol_cli_cloud_lifecycle.Prepared preparation -> preparation
             | Sol_cli_cloud_lifecycle.Nothing_to_prepare
             | Sol_cli_cloud_lifecycle.Preparation_failed _ -> Nothing_prepared
           in
           (match teardown ~deps ~substrate with
            | Error (failure, cleanup) -> fail ~cleanup failure
            | Ok (cleanup, teardown_degradations) ->
              teardown_degradations
              |> List.iter (fun message -> degradations := message :: !degradations);
              (match cleanup with
               | Cleanup_failed message ->
                 degrade
                   "elevated access"
                   (Printf.sprintf
                      "%s -- the binding this removes lives inside the cluster, so it is \
                       removed with the substrate; destruction continues and the absence \
                       check decides whether anything is left"
                      message);
                 destroy_and_verify ~cloud_exists ~cleanup ~preparation
               | Cleanup_not_needed | Cleanup_succeeded ->
                 destroy_and_verify ~cloud_exists ~cleanup ~preparation))))
;;

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
