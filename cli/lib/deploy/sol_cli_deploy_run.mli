(** What [sol deploy] does once its selection and plan are decided (REFAC-139,
    part E): the AUDIT-069 migration gate, the lease-bracketed apply attempt,
    the release record, and the reads its report is built from. The command
    builds the {!context}, calls these and renders; nothing here exits, and
    progress is reported through {!Sol_cli_report}. *)

type context =
  { execution : Sol_cli_execution.context
  ; sha : string
  ; registry : string
  ; facts : Sol_cli_workspace_model.t
    (** REFAC-130: the workspace, read once in [run]. Everything this deploy
        needs about the workspace -- the inventory, each unit's [sol.toml], its
        topics, migrations and schema subjects -- is a projection of it. *)
  ; secret_backend : Sol_cli_manifest.secret_backend
    (** INFRA-050: already resolved -- the operator's explicit choice, else the
          destination's default. Resolved once in [run], so every path (dry-run,
          emit, apply) uses the same decision. *)
  ; emit_plan_to : string option
  ; target_cfg : Sol_cli_config.target
  ; resolved_config : Sol_cli_config.t
  ; services : Sol_cli_manifest.service list
    (** The *selection* — what this deploy applies. Determined by [--scope] and
        never widened (DEC-036). *)
  ; inventory : Sol_cli_manifest.service list
    (** Everything discovery found. Call references resolve against this, so a
        unit can be deployed alone while still naming a callee that already
        exists in the workspace (DEC-036). Never what gets deployed. *)
  ; image_refs : (string * string) list
    (** FEAT-050: resolved per-service immutable references for this
          invocation, [service_name -> repo@sha256:<digest>]. Empty when no
          [--image-ref] was supplied, which keeps the tag path unchanged. *)
  ; requested_scope : string
  ; target_name : string
  ; run_log : Sol_cli_run_log.t
  ; keep_releases : int
  }

(** [http_services ~ctx results]: the deployed HTTP services (ClusterIP Services
    on port 80) among [results]. Best effort: it feeds a hint, so a read that
    fails lists nothing. *)
val http_services
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_executor.result list
  -> string list

(** FEAT-050: every supplied [--image-ref] resolves in its registry; the error
    names the first that does not. *)
val verify_image_refs_exist : image_refs:(string * string) list -> (unit, string) result

(** [run_plan_result ctx ~phase ~mode plan]: run [plan] in [mode] as the run
    log's [phase] task. *)
val run_plan_result
  :  context
  -> phase:string
  -> mode:Sol_cli_executor.mode
  -> ?before_apply:(Sol_cli_deployment_plan.service_spec -> (unit, string) result)
  -> Sol_cli_deployment_plan.t
  -> (Sol_cli_executor.result list, string) result

type gate_failure =
  | Refused of string (** Sol could not establish the gate's substrate *)
  | Failed of string (** the gate's own report, printed as given *)

(** AUDIT-069: a production-profile deploy's required migrations are applied.
    [live:false] (dry run, [--emit-to]) creates nothing and reports the
    prerequisite as not verified; a deploy with no profile is not checked. *)
val migration_prerequisite
  :  context
  -> plan:Sol_cli_deployment_plan.t
  -> live:bool
  -> (unit, gate_failure) result

(** FEAT-071: one deploy marker per deployed service, joined to the
    authoritative deployment event by [deployment_id]. *)
val deploy_events
  :  workspace:string
  -> target_cfg:Sol_cli_config.target
  -> deployment_id:Sol_cli_deployment_id.t
  -> Sol_cli_deployment_plan.t
  -> Sol_cli_deploy_event.t list

(** FEAT-074: the live Sol-owned workloads a whole-workspace deploy did not
    include. Empty for a scoped deploy, and when the live set cannot be read. *)
val surplus_workloads
  :  context
  -> Sol_cli_deployment_plan.t
  -> Sol_cli_rollback.workload_identity list

(** [apply ctx ~push_events ~report_success plan], under the workspace boundary
    lease: apply, record exactly one deployment event, push the markers (only
    for a recorded, applied attempt), then record the release (DEC-037) and
    only then [report_success]. A release that cannot be recorded fails the
    deploy. *)
val apply
  :  context
  -> push_events:(Sol_cli_deploy_event.t list -> unit)
  -> report_success:(Sol_cli_executor.result list -> unit)
  -> Sol_cli_deployment_plan.t
  -> (unit, string) result
