(* REFAC-139, part E: what `sol deploy` does once its selection and plan are
   decided -- the AUDIT-069 migration gate, the lease-bracketed apply attempt, the
   release record, and the reads that feed its report. It lived in
   `cmd_deploy.ml`; the command now builds the [context], calls these and renders.
   Nothing here exits; progress goes through [Sol_cli_report]. *)

open Result.Syntax

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

(* EXP-029: the HTTP services this deploy created -- the ClusterIP Services
   listening on port 80, the same detection cmd_status.ml's print_raw_diagnostics
   uses. Only Svc-primitive services ever get a Service resource
   (sol_cli_deployment_render.ml only emits service_doc for Http_service shapes),
   so this naturally excludes worker/fn services. Best effort: it feeds a hint,
   so a read that fails lists nothing rather than failing the deploy. *)
let http_services ~ctx (results : Sol_cli_executor.result list) =
  let deployed = results |> List.map (fun r -> r.Sol_cli_executor.name) in
  let cluster_ip_services ns =
    let jsonpath = "{.items[?(@.spec.type==\"ClusterIP\")].metadata.name}" in
    match
      Sol_cli_kubectl.get_raw
        ~ctx
        ~args:[ "get"; "svc"; "-n"; ns; "-o"; "jsonpath=" ^ jsonpath ]
    with
    | Ok r ->
      String.split_on_char ' ' r.stdout |> List.filter_map Sol_cli_string.non_blank
    | Error _ -> []
  in
  let serves_port_80 ns name =
    match
      Sol_cli_kubectl.get
        ~ctx
        ~resource:"svc"
        ~name
        ~namespace:ns
        ~output:"jsonpath={.spec.ports[?(@.port==80)].port}"
    with
    | Ok r -> Option.is_some (Sol_cli_string.non_blank r.stdout)
    | Error _ -> false
  in
  results
  |> List.map (fun r -> r.Sol_cli_executor.namespace)
  |> List.sort_uniq String.compare
  |> List.concat_map (fun ns ->
    cluster_ip_services ns
    |> List.filter (fun name -> List.mem name deployed && serves_port_80 ns name))
;;

(* FEAT-050: a supplied artifact reference must resolve before anything is
   mutated, and a missing digest names the reference rather than surfacing
   later as an opaque image-pull failure. Apply-only by design: --dry-run and
   --emit-to are offline paths that touch no registry. *)
let verify_image_refs_exist ~image_refs =
  match
    image_refs
    |> List.find_opt (fun (_, ref) -> not (Sol_cli_docker.manifest_exists ~image_ref:ref))
  with
  | None -> Ok ()
  | Some (service, ref) ->
    Error
      (Printf.sprintf
         "--image-ref for service %s was not found in its registry: %s\n\
         \  (docker manifest inspect failed; check the repository, digest and registry \
          credentials)\n\
         \  Nothing was applied."
         service
         ref)
;;

(* REFAC-089: the record the caller already holds is the parameter. Every input
   here except [phase] and [mode] is a property of *this deploy invocation* --
   workspace, run log, target environment, destination, secret backend -- not a
   choice this execution makes, so listing them as labelled arguments unpacked
   [deploy_context] only to repack it. *)
let run_plan_result ctx ~phase ~mode ?before_apply plan =
  Sol_cli_run_log.run_task ctx.run_log ~name:phase (fun () ->
    Sol_cli_factory.execute
      ctx.execution
      ~mode
      ~secret_backend:ctx.secret_backend
      ?before_apply
      plan)
;;

(* ── AUDIT-069: the migration prerequisite ───────────────────────────────────

   The production profile's release-safety contract includes "application code
   is not rolled out against a known-incompatible database migration state". The
   deployable revision defines the schema it expects: every migration in the
   workspace's [db/migrations] must already be applied (required ⊆ applied,
   verified against the authoritative [schema_migrations] table). There is no
   second Sol-side record of "which migrations matter".

   The order is deliberate: static preflight -> live migration-status
   verification -> workload mutation. [--dry-run] and [--emit-to] are
   side-effect free, so they create no Job and report the prerequisite as
   requiring live verification -- never as established. A non-production deploy
   (no selected profile) makes no such claim and is not checked. *)
type gate_failure =
  | Refused of string (** Sol could not establish the gate's substrate *)
  | Failed of string (** the gate's own report, printed as given *)

let migration_prerequisite ctx ~plan ~live =
  match plan.Sol_cli_deployment_plan.profile with
  | None -> Ok ()
  | Some _ ->
    (* REFAC-130: the workspace's migrations, at the workspace root -- not
       "db/migrations" relative to whatever directory the deploy was invoked
       from. [sol deploy] keeps the invocation cwd, so a cwd-relative read found
       nothing from a descendant directory and the gate silently reported "no
       migrations" for a workspace that has them. *)
    let dir =
      Filename.concat ctx.facts.Sol_cli_workspace_model.root Sol_cli_migration.default_dir
    in
    if not live
    then (
      (* Side-effect free: report honestly instead of creating anything. *)
      match Sol_cli_migration.required ~dir with
      | Ok [] | Error _ -> Ok ()
      | Ok _ ->
        Sol_cli_report.app
          "Migrations: NOT verified -- a side-effect-free run creates no status Job. The \
           applied migration set is only checked against the live cluster by a real \
           deploy (before any workload moves).";
        Ok ())
    else
      (* HARDEN-002 run 2, finding 8: this gate needs the workspace substrate --
         the application namespace and the runtime Secret -- and workload
         mutation, which used to create both, happens *after* this gate. Establish
         it here, so the gate never depends on something behind itself. Not
         workload mutation: a namespace and a Secret are not a Deployment, and
         AUDIT-069's invariant is untouched. *)
      let* () =
        Sol_cli_substrate.ensure
          ~ctx:ctx.execution.cluster
          ~namespaces:(Sol_cli_substrate.namespaces plan)
        |> Result.map_error (fun message -> Refused message)
      in
      Sol_cli_migration_gate.reconcile_operator_bindings
        ~ctx:ctx.execution.cluster
        ~workspace:ctx.execution.workspace
        ~services:ctx.inventory;
      (match
         Sol_cli_migration_gate.verify
           ~ctx:ctx.execution.cluster
           ~target:ctx.target_name
           ~workspace:ctx.execution.workspace
           ~dir
           ~services:ctx.inventory
       with
       | Sol_cli_migration_gate.No_migrations -> Ok ()
       | Sol_cli_migration_gate.Satisfied applied ->
         Sol_cli_report.app
           "Migrations: OK -- %d declared migration(s) present in schema_migrations"
           (List.length applied);
         Ok ()
       | Sol_cli_migration_gate.Unsatisfied missing ->
         Error
           (Failed
              (Printf.sprintf
                 "\n\
                  error: the required migration set is not applied. Missing: %s\n\
                 \  Migrations are workspace-wide, so this is the same set whatever \
                  scope the deploy selected. Run `sol migrate apply %s`, then deploy \
                  again."
                 (String.concat ", " (List.map Sol_cli_migration.to_string missing))
                 ctx.target_name))
       | Sol_cli_migration_gate.Unavailable reason ->
         Error
           (Failed
              (Printf.sprintf
                 "\n\
                  error: cannot verify the required migration state: %s\n\
                 \  A deploy against the production profile fails closed rather than \
                  assume the schema is compatible. Migrations are workspace-wide -- the \
                  deploy's scope does not select them -- so `sol migrate apply %s` \
                  checks the same required set this deploy did (it reports the applied \
                  set). Run it, then deploy again."
                 reason
                 ctx.target_name)))
;;

(* FEAT-071: one deploy marker per deployed service, joined to the authoritative
   deployment event by [deployment_id]. *)
let deploy_events ~workspace ~(target_cfg : Sol_cli_config.target) ~deployment_id plan =
  plan.Sol_cli_deployment_plan.services
  |> List.map (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    { Sol_cli_deploy_event.workspace
    ; env = target_cfg.env
    ; domain = spec.domain
    ; service = Sol_cli_kubernetes_name.k8s_name_to_string spec.k8s_name
    ; primitive =
        Sol_cli_manifest.primitive_label
          (match spec.primitive with
           | Sol_cli_deployment_plan.Svc -> Sol_cli_manifest.Svc
           | Worker -> Sol_cli_manifest.Worker
           | Fn -> Sol_cli_manifest.Fn)
    ; release_id = plan.Sol_cli_deployment_plan.release_id
    ; deployment_id
    })
;;

(* Read the release the pointer names now. Deliberately three-valued: the value
   feeds retention's "protect the previous release", so a read that failed must
   not become "there is no previous release" -- that would drop the protection
   exactly when it could not be established. Retention refuses to prune on
   [Unreadable] and reports why. *)
let read_previous_release ctx =
  match
    Sol_cli_release_store.current
      ~ctx:ctx.execution.cluster
      ~workspace:ctx.execution.workspace
  with
  | Ok (Some release_id) -> Sol_cli_release_retention.Known release_id
  | Ok None -> Sol_cli_release_retention.None_yet
  | Error msg -> Sol_cli_release_retention.Unreadable msg
;;

(* Post-apply bookkeeping, non-fatal by construction: record the release, then
   bound the workspace's history. A failure here warns; it never turns a
   successful deploy into a failed one. *)
(* DEC-037: recording the release is part of the deploy's outcome, not
   bookkeeping after it. The pointer this writes is what `sol rollback` restores
   and what release retention anchors on, so a deploy that cannot advance it has
   not succeeded -- and must say so rather than printing a success line over a
   release state that still describes the previous release.

   Pruning stays best-effort: it is housekeeping over old records, not the
   release identity. *)
let record_release_and_prune ctx ~previous plan =
  let cluster = ctx.execution.cluster in
  let workspace = ctx.execution.workspace in
  match
    Sol_cli_release_store.record_plan ~ctx:cluster ~apply_mode:Sol_cli_release.Direct plan
  with
  | Error msg ->
    Error
      (Printf.sprintf
         "the release was applied but could not be recorded: %s\n\
         \  The workloads for this release may already be running; the release state was \
          not advanced, so `sol rollback` and release retention still describe the \
          previous release.\n\
         \  Fix the cause and deploy again -- nothing on the cluster needs undoing."
         msg)
  | Ok () ->
    (match
       Sol_cli_release_retention.prune
         ~ctx:cluster
         ~workspace
         ~keep:ctx.keep_releases
         ~current:(Sol_cli_release_id.to_string plan.release_id)
         ~previous
     with
     | Ok [] -> ()
     | Ok pruned ->
       Sol_cli_report.app
         "Pruned %d release record(s) beyond the last %d."
         (List.length pruned)
         ctx.keep_releases
     | Error msg -> Sol_cli_report.warn "warning: could not prune old releases: %s" msg);
    Ok ()
;;

(* FEAT-074: report-only, and only for a whole-workspace deploy -- see
   cmd_up.ml's identical rationale (a scoped deploy's [plan.services] is a
   subset of the workspace, so comparing it against every live Sol-owned
   workload would false-flag out-of-scope services; a deploy never deletes,
   since it has no recorded release boundary the way [sol rollback] does).
   Best-effort -- a failure here must not fail an otherwise-successful
   deploy, so an unreadable live set reports nothing. *)
let surplus_workloads ctx (plan : Sol_cli_deployment_plan.t) =
  if not (String.equal ctx.requested_scope "workspace")
  then []
  else (
    match
      Sol_cli_rollback.live_workloads
        ~ctx:ctx.execution.cluster
        ~workspace:ctx.execution.workspace
    with
    | Error _ -> []
    | Ok live ->
      Sol_cli_rollback.unexpected_workloads ~expected:plan.services ~live |> List.map fst)
;;

(* One deploy attempt: mint the id, apply (refreshing the lease between
   workloads), derive the outcome, then record exactly one immutable event --
   success or failure -- and push the markers only if that event exists and the
   apply succeeded (FEAT-071: a marker is a join key to the authoritative event).
   The release record is deliberately *not* written here: a failed attempt cannot
   claim a release exists. *)
let execute_deployment_attempt ctx ~before_apply ~push_events plan =
  let attempt = Sol_cli_deployment_attempt.start () in
  let applied =
    run_plan_result ctx ~phase:"apply" ~mode:Sol_cli_executor.Apply ~before_apply plan
  in
  let outcome = Sol_cli_deployment_attempt.outcome_of applied in
  let recorded =
    Sol_cli_deployment_attempt.record
      ~ctx:ctx.execution.cluster
      ~target:(Some ctx.target_name)
      plan
      attempt
      outcome
  in
  (match outcome with
   | Sol_cli_deployment.Applied when recorded ->
     push_events
       (deploy_events
          ~workspace:ctx.execution.workspace
          ~target_cfg:ctx.target_cfg
          ~deployment_id:(Sol_cli_deployment_attempt.deployment_id attempt)
          plan)
   | _ -> ());
  applied
;;

let apply ctx ~push_events ~report_success plan =
  Sol_cli_boundary_lease.with_boundary_lease
    ~ctx:ctx.execution.cluster
    ~workspace:ctx.execution.workspace
    ~holder:Sol_cli_boundary_lease.Deploy
    ~ttl:Sol_cli_boundary_lease.default_ttl_s
    ~wait_s:0.
    (fun lease ->
       let previous = read_previous_release ctx in
       let* results =
         execute_deployment_attempt
           ctx
           ~before_apply:(fun _ -> Sol_cli_boundary_lease.ensure_held lease)
           ~push_events
           plan
       in
       (* DEC-037: record first, report second. If the authoritative release
          state cannot be written, this deploy has not succeeded, so it must
          neither print a success line nor exit zero -- and the message names
          that the workloads may already be running. *)
       Sol_cli_release.finish_deployment
         ~record_release:(fun () ->
           let* () = record_release_and_prune ctx ~previous plan in
           (* BUG-045: see Sol_cli_deployment_state.save_deployed_groups. *)
           Sol_cli_deployment_state.record_outcome
             ~ctx:ctx.execution.cluster
             ctx.execution.workspace
             (Sol_cli_deployment_state.Applied
                { namespace = "default"
                ; name = ctx.execution.workspace
                ; image = ctx.sha
                ; consumer_groups =
                    List.map
                      Sol_cli_plan_ids.Consumer_group.to_string
                      plan.consumer_groups
                }))
         ~report_success:(fun () -> report_success results))
;;
