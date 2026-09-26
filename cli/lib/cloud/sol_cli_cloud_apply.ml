(* REFAC-091 (install half, plan stage S7): the cloud apply as a sequence that returns
   a typed outcome, the shape [Sol_cli_cloud_destroy.execute] already has.

   It used to be the body of `cmd_cloud_tf.cloud_init`, where every failure `exit`ed
   from inside a helper. That made two things true that should not be. Cleanup of the
   bootstrap window was hand-threaded through an [on_error] argument to each failure
   branch, so a branch that forgot it left the window open (FND-0047): the two
   refusals of the observed lifecycle phase were such branches. And the sequence could
   not be run offline.

   Here the bootstrap window is bracketed structurally. It opens with the cloud apply,
   and any failure while it is open removes it before the outcome is returned. It
   closes when the sequence itself removes it; that removal is not retried as its own
   cleanup, and nothing after it needs one.

   Every provider-specific step is a dependency; nothing here selects a provider. The
   command edge maps the outcome to the process exit. *)

type failure =
  | Terraform_failed of string
  (** A Terraform command failed; the text is Terraform's own classification. *)
  | Refused of string (** Sol refused to continue; the text is the reason. *)

type outcome =
  | Applied
  | Apply_failed of
      { failure : failure
      ; cleanup : Sol_cli_cloud_destroy.cleanup
      }

type ('outputs, 'env, 'control) deps =
  { substrate_exists : unit -> (bool, string) result
  ; plan : unit -> (Sol_cli_terraform_plan.change list, failure) result
  ; guarded_removals : string list
  ; confirm_guarded_removal : bool
  ; confirmation_flag : string
  ; apply_plan : unit -> (unit, failure) result
  ; discard_plan : unit -> unit
  ; outputs : unit -> ('outputs option, string) result
  ; open_window : 'outputs -> ('control option, string) result
  ; platform_vars : 'outputs -> (string list, string) result
  ; cloud_ready : 'outputs -> (unit, string) result
  ; observe_disk_quota :
      'outputs -> (Sol_cli_disk_quota.observation option, string) result
  ; with_cluster_access :
      'outputs -> ('env -> (unit, failure) result) -> (unit, failure) result
  ; platform_init : unit -> (unit, failure) result
  ; platform_installed : 'env -> bool
  ; apply_prerequisites : 'env -> string list -> (unit, failure) result
  ; await_crds : 'env -> bool
  ; apply_platform : 'env -> string list -> (unit, failure) result
  ; await_readiness : 'env -> (string * Sol_cli_cloud_lifecycle.readiness) list
  ; remove_bootstrap_access : unit -> (unit, failure) result
  ; verify_deescalation : 'outputs -> 'control option -> (unit, string) result
  ; provisioner_effective : 'env -> bool
  ; report : string -> unit
  }

let failure_to_string = function
  | Terraform_failed message | Refused message -> message
;;

let refused result = Result.map_error (fun message -> Refused message) result
let ( let* ) = Result.bind

let report_phase deps phase =
  deps.report
    (Printf.sprintf
       "  lifecycle phase: %s"
       (Sol_cli_cloud_lifecycle.phase_to_string phase))
;;

(* INFRA-074 / FND-0043, generalised by AUDIT-POST-002: a resource type the provider
   declares *guarded* holds something a re-apply cannot restore (AWS's ECR repositories
   are derived from the workloads with a Dockerfile in this checkout, so a branch that
   lacks one plans its deletion with [force_delete], taking its images with it). A plan
   that removes one is refused before anything is applied unless the operator confirms
   it. Which types those are is the provider's declaration; the policy is Sol's. *)
let check_guarded_removals deps changes =
  let removed =
    List.concat_map
      (fun resource_type -> Sol_cli_terraform_plan.removed_of_type ~resource_type changes)
      deps.guarded_removals
  in
  match removed with
  | [] -> Ok ()
  | removed when deps.confirm_guarded_removal ->
    deps.report
      (Printf.sprintf
         "  guarded removal: deleting %s (confirmed with %s)"
         (String.concat ", " removed)
         deps.confirmation_flag);
    Ok ()
  | removed ->
    Error
      (Refused
         (Printf.sprintf
            "this apply would delete %s and everything in them.\n\
            \  Sol refuses to remove what a re-apply cannot restore unless the removal \
             is intended: run from the checkout that deploys this target, or pass %s. \
             Nothing was changed."
            (String.concat ", " removed)
            deps.confirmation_flag))
;;

(* ADR 0003 invariant 3: a platform change on an already-installed target is an
   explicit PlatformUpdating re-entry, never an implicit return to
   PlatformInstalling. The phases [observed_phase] cannot produce today are refused
   rather than matched, so widening the observation cannot silently admit an apply
   from a phase the relation does not allow one from. *)
let operation_phase observed =
  match (observed : Sol_cli_cloud_lifecycle.phase) with
  | Ready -> Sol_cli_cloud_lifecycle.enter ~from:Ready ~to_:Platform_updating |> refused
  | Absent | Platform_installing -> Ok Sol_cli_cloud_lifecycle.Platform_installing
  | (Cloud_bootstrap | Platform_updating | Preparing_destroy | Destroying) as other ->
    Error
      (Refused
         (Printf.sprintf
            "refusing to apply from observed lifecycle phase %s"
            (Sol_cli_cloud_lifecycle.phase_to_string other)))
;;

(* Everything that runs while the bootstrap window is open. [closing] is set just
   before the sequence removes the window itself, so a failure from then on is not
   answered by a second removal. *)
let install_platform deps ~closing =
  let* outputs =
    match deps.outputs () with
    | Ok (Some outputs) -> Ok outputs
    | Ok None -> Error (Refused "Terraform apply completed without lifecycle outputs")
    | Error message -> Error (Refused message)
  in
  (* DEC-040's gate and positive control, captured while the window this run
     opened is still open. *)
  let* control = deps.open_window outputs |> refused in
  (match control with
   | Some _ -> ()
   | None -> deps.report "  bootstrap window control: not captured");
  let* platform_vars = deps.platform_vars outputs |> refused in
  let* () = deps.cloud_ready outputs |> refused in
  (* INFRA-090 / FND-0062: the substrate exists now, so the provider's own footprint -- the
     cluster it has already created -- is inside the observed usage, while Sol's volumes are
     not, because none exists yet. That is the earliest point at which an observation means
     anything and the latest at which refusing still costs nothing.

     Observation is the provider's (it may declare none); the requirement is Sol's; the
     comparison is this sequence's policy. How much quota the provider's own nodes will consume
     is deliberately not modelled -- Attempt 12's cluster had spent the whole allowance on
     itself before the platform asked for a byte, and predicting that would mean reproducing
     Autopilot's scheduling behaviour. *)
  let* () =
    match deps.observe_disk_quota outputs with
    | Error message -> Error (Refused message)
    | Ok None ->
      Ok
        (deps.report
           "  platform volumes: the provider declares no disk-quota observation, so this \
            run cannot say whether they fit")
    | Ok (Some observation) ->
      deps.report
        (Printf.sprintf
           "  platform volumes: %s, and the platform's declared minimum is %d GiB (%s)"
           (Sol_cli_disk_quota.describe observation)
           Sol_cli_platform_storage.minimum_gb
           (Sol_cli_platform_storage.describe ()));
      Sol_cli_disk_quota.sufficient
        ~observation
        ~required_gb:Sol_cli_platform_storage.minimum_gb
      |> refused
  in
  deps.with_cluster_access outputs (fun env ->
    let* () = deps.platform_init () in
    (* ADR 0003: the phase is recomputed from observation before this run creates
       anything. The cert-manager CRDs are cluster objects, so they report what an
       *earlier* run installed and are unaffected by this run's escalation. *)
    let observed =
      Sol_cli_cloud_lifecycle.observed_phase
        ~cloud_exists:true
        ~platform_installed:(deps.platform_installed env)
    in
    let* phase = operation_phase observed in
    report_phase deps phase;
    let* () = deps.apply_prerequisites env platform_vars in
    let* () =
      if deps.await_crds env
      then Ok ()
      else Error (Refused "cert-manager CRDs did not become Established")
    in
    (* ADR 0003 / HARDEN-002 run 4 finding 14: the platform install is privileged
       establishment, so the window stays open through the full platform apply AND
       verified readiness, and is removed only at the transition to Ready. *)
    let* () = deps.apply_platform env platform_vars in
    let summary = Sol_cli_cloud_lifecycle.readiness_summary (deps.await_readiness env) in
    let* () =
      if summary = "Ready"
      then Ok ()
      else Error (Refused ("platform readiness " ^ summary))
    in
    closing := true;
    let* () = deps.remove_bootstrap_access () in
    (* DEC-040: Ready is a claim of least privilege, so it is not announced until
       the effective authorization surface shows the bootstrap capability gone. *)
    let* () = deps.verify_deescalation outputs control |> refused in
    let* _ =
      Sol_cli_cloud_lifecycle.enter ~from:phase ~to_:Sol_cli_cloud_lifecycle.Ready
      |> refused
    in
    let* () =
      if deps.provisioner_effective env
      then Ok ()
      else
        Error
          (Refused
             "platform provisioner RBAC is not effective after bootstrap access removal")
    in
    (* ADR 0003 / INFRA-031: reported only once readiness is verified, the window
       removed and the bounded provisioner verified effective. *)
    report_phase deps Sol_cli_cloud_lifecycle.Ready;
    Ok ())
;;

let execute ~deps =
  (* ADR 0003 / INFRA-031: a target with no substrate is in CloudBootstrap, reported
     before the apply that creates it. Only a positive "no substrate" justifies the
     claim; an unreadable state fails closed. *)
  let cloud_stage () =
    let* exists = deps.substrate_exists () |> refused in
    if not exists then report_phase deps Sol_cli_cloud_lifecycle.Cloud_bootstrap;
    let* changes = deps.plan () in
    let* () = check_guarded_removals deps changes in
    deps.apply_plan ()
  in
  match Fun.protect ~finally:deps.discard_plan cloud_stage with
  | Error failure -> Apply_failed { failure; cleanup = Cleanup_not_needed }
  | Ok () ->
    let closing = ref false in
    (match install_platform deps ~closing with
     | Ok () -> Applied
     | Error failure when !closing ->
       Apply_failed { failure; cleanup = Cleanup_not_needed }
     | Error failure ->
       let cleanup =
         match deps.remove_bootstrap_access () with
         | Ok () -> Sol_cli_cloud_destroy.Cleanup_succeeded
         | Error removal -> Cleanup_failed (failure_to_string removal)
       in
       Apply_failed { failure; cleanup })
;;
