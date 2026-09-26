(* sol deploy — CI/CD integration.
   Like sol up but skips the build step: images are already in a registry.
   Designed to run in CI after the build pipeline has pushed images. *)

open Cmdliner
open Sol_cli_manifest

(* DEC-024: the workspace name comes from the resolved root, so it is the same
   from any descendant directory. *)
let workspace_name = Sol_cli_workspace.current_name

(* DEC-038 §6 / INFRA-058: the operator's diagnostic grant follows the workload,
   not this command's scope, so reconcile it across every namespace that holds a
   Sol-managed workload. RBAC only -- it writes RoleBindings and nothing else.

   A failure here is a warning, not fatal: a deployment must not be blocked by a
   read-only grant. But it is never silent -- the warning names what could not be
   established and what it costs, because a diagnostic capability that quietly
   did not appear is the failure mode this whole line of work exists to remove. *)
let reconcile_operator_bindings_warn ~ctx ~workspace =
  match Sol_cli_substrate.reconcile_operator_bindings ~ctx ~workspace with
  | Ok () -> ()
  | Error msg ->
    Printf.eprintf
      "warning: could not establish the operator's diagnostic RoleBindings: %s\n\
       The operator identity will not be able to read this workspace's workloads.\n\
       %!"
      msg
;;

(* EXP-029: after a real apply, print a port-forward hint for each HTTP
   service so the engineer doesn't need a separate 'sol status' call to
   discover the endpoint. Same ClusterIP+port-80 detection cmd_status.ml's
   print_raw_diagnostics already uses -- only Svc-primitive services ever
   get a Service resource (sol_cli_deployment_render.ml only emits
   service_doc for Http_service shapes), so this naturally excludes
   worker/fn services without needing to thread primitive info through. *)
let print_service_urls ~ctx (results : Sol_cli_executor.result list) =
  let deployed_names =
    List.map (fun (r : Sol_cli_executor.result) -> r.Sol_cli_executor.name) results
  in
  let namespaces =
    List.sort_uniq
      compare
      (List.map
         (fun (r : Sol_cli_executor.result) -> r.Sol_cli_executor.namespace)
         results)
  in
  List.iter
    (fun ns ->
       let jsonpath = "{.items[?(@.spec.type==\"ClusterIP\")].metadata.name}" in
       match
         Sol_cli_process.check
           (Sol_cli_kubectl.get_raw
              ~ctx
              ~args:[ "get"; "svc"; "-n"; ns; "-o"; "jsonpath=" ^ jsonpath ])
       with
       | Ok r when r.Sol_cli_process.stdout <> "" ->
         let port80_jsonpath = "{.spec.ports[?(@.port==80)].port}" in
         String.split_on_char ' ' r.Sol_cli_process.stdout
         |> List.filter (fun name -> List.mem name deployed_names)
         |> List.iter (fun name ->
           match
             Sol_cli_kubectl.get
               ~ctx
               ~resource:"svc"
               ~name
               ~namespace:ns
               ~output:("jsonpath=" ^ port80_jsonpath)
           with
           | Ok gr when gr.Sol_cli_process.stdout <> "" ->
             Printf.printf "  →  http://localhost:8080  (%s)\n%!" name
           | _ -> ())
       | _ -> ())
    namespaces
;;

let check_contract ~services =
  let findings = Sol_cli_check.run_services services in
  List.iter (fun f -> Printf.eprintf "%s\n" (Sol_cli_check.finding_to_string f)) findings;
  if Sol_cli_check.has_errors findings then exit 1
;;

let ensure_postgres_url () =
  match Sys.getenv_opt "POSTGRES_URL" with
  | None | Some "" ->
    Printf.eprintf
      "error: POSTGRES_URL is not set.\n\
       Set it in your environment before running 'sol deploy':\n\
      \  export POSTGRES_URL=postgresql://user:pass@host:5432/dbname\n";
    exit 1
  | Some _ -> ()
;;

let check_consumer_group_changes ~ctx ~workspace ~confirm_group_change plan =
  match
    Sol_cli_deployment_state.check_removed_groups
      ~ctx
      ~workspace
      ~confirm_group_change
      ~next:
        (List.map
           Sol_cli_plan_ids.Consumer_group.to_string
           plan.Sol_cli_deployment_plan.consumer_groups)
  with
  | Ok () -> ()
  | Error msg ->
    Printf.eprintf "%s\n%!" msg;
    exit 1
;;

let check_apply_environment ~services =
  check_contract ~services;
  ensure_postgres_url ()
;;

(* FEAT-050: a supplied artifact reference must resolve before anything is
   mutated, and a missing digest names the reference rather than surfacing
   later as an opaque image-pull failure. Apply-only by design: --dry-run and
   --emit-to are offline paths that touch no registry. *)
let verify_image_refs_exist ~image_refs =
  List.iter
    (fun (service, ref) ->
       if not (Sol_cli_docker.manifest_exists ~image_ref:ref)
       then (
         Printf.eprintf
           "error: --image-ref for service %s was not found in its registry: %s\n\
           \  (docker manifest inspect failed; check the repository, digest and registry \
            credentials)\n\
           \  Nothing was applied.\n"
           service
           ref;
         exit 1))
    image_refs
;;

type deploy_context =
  { execution : Sol_cli_execution.context
  ; sha : string
  ; registry : string
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

let print_header ~workspace ~sha ?mode_line () =
  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  Option.iter (Printf.printf "%s\n") mode_line;
  Printf.printf "\n%!"
;;

let build_plan ctx ~emit_to =
  let env_target =
    Sol_cli_exit.or_exit
      (Sol_cli_env_target.customer_cloud_defaults
         ~registry:ctx.registry
         ~image_tag:ctx.sha
         ~emit_to
         ())
  in
  (* Guard: Kubernetes_live is never allowed with a GitOps target. Combining the
     two would write plaintext secret values into the GitOps repository, leaking
     them to everyone with read access to the repo. [ctx.secret_backend] is
     already resolved (INFRA-050), so this fires only on an explicit
     --secret-backend kubernetes-live: an absent flag resolves to the GitOps
     destination's own placeholder. *)
  (match env_target, ctx.secret_backend with
   | Sol_cli_env_target.Customer_gitops _, Sol_cli_manifest.Kubernetes_live ->
     Printf.eprintf
       "error: cannot use --secret-backend kubernetes-live with --emit-to (GitOps mode).\n\
       \  This combination would write plaintext secrets into the GitOps repository,\n\
       \  leaking them to every reader of the repo.\n\
       \  Use --secret-backend kubernetes-placeholder (the default) or --secret-backend \
        external-secrets instead.\n";
     exit 1
   | _ -> ());
  let env =
    { (Sol_cli_env_target.to_env_config ~name:ctx.execution.workspace env_target) with
      Sol_cli_deployment_plan.secret_backend = ctx.secret_backend
    ; env = Some ctx.target_cfg.Sol_cli_config.env
    ; cluster_issuer =
        Option.value
          ctx.target_cfg.Sol_cli_config.cluster_issuer
          ~default:"letsencrypt-prod"
    }
  in
  let plan =
    Sol_cli_exit.or_exit
      (Sol_cli_factory.plan_of_services
         ~workspace:ctx.execution.workspace
         ~env
         ~requested_scope:ctx.requested_scope
         ~resolved_config:ctx.resolved_config
         ~image_refs:ctx.image_refs
         ~inventory:ctx.inventory
         ctx.services)
  in
  (* FEAT-089: the profile preflight runs once, here, because every deploy
       path (dry-run, --emit-to, apply) builds its plan through this function
       before any lease, cluster mutation or emitted file. *)
  let apply_mode =
    match emit_to with
    | Some _ -> Sol_cli_release.Gitops
    | None -> Sol_cli_release.Direct
  in
  match Sol_cli_profile_preflight.check ~target:ctx.target_cfg ~apply_mode plan with
  | Error (profile, findings) ->
    prerr_string (Sol_cli_profile_preflight.report profile findings);
    exit 1
  | Ok () ->
    Option.iter
      (fun (claim : Sol_cli_deployment_plan.profile_claim) ->
         Printf.printf
           "Profile: %s (preflight passed)\n%!"
           (Sol_cli_profile.to_string claim.profile))
      plan.Sol_cli_deployment_plan.profile;
    plan
;;

let write_plan_if_requested ~emit_plan_to plan =
  match emit_plan_to with
  | None -> ()
  | Some path ->
    let json_str = Yojson.Safe.pretty_to_string (Sol_cli_deployment_plan.to_json plan) in
    if path = "-"
    then (
      print_string json_str;
      print_char '\n')
    else (
      let oc = open_out path in
      output_string oc json_str;
      output_char oc '\n';
      close_out oc;
      Printf.printf "Plan written to %s\n%!" path)
;;

let to_manifest_primitive = function
  | Sol_cli_deployment_plan.Svc -> Svc
  | Sol_cli_deployment_plan.Worker -> Worker
  | Sol_cli_deployment_plan.Fn -> Fn
;;

let print_planned_services plan =
  List.iter
    (fun (spec : Sol_cli_deployment_plan.service_spec) ->
       Printf.printf
         "[%s] %s/%s\n%!"
         (primitive_label (to_manifest_primitive spec.primitive))
         spec.domain
         spec.source_name)
    plan.Sol_cli_deployment_plan.services
;;

let record_plan run_log plan =
  Sol_cli_run_log.append_phase_log
    run_log
    ~phase:"plan"
    (Format.asprintf "%a" Sol_cli_deployment_plan.pp_summary plan)
;;

(* REFAC-089: the record the caller already holds is the parameter. Every input
   here except [phase] and [mode] is a property of *this deploy invocation* --
   workspace, run log, target environment, destination, secret backend -- not a
   choice this execution makes, so listing them as labelled arguments unpacked
   [deploy_context] only to repack it. *)
let run_plan_result ctx ~phase ~mode ?before_apply plan =
  Sol_cli_run_log.run_task ctx.run_log ~name:phase (fun () ->
    try
      Sol_cli_factory.execute
        ctx.execution
        ~mode
        ~secret_backend:ctx.secret_backend
        ?before_apply
        plan
    with
    | Deploy_failed msg -> Error msg)
;;

(* The dry-run/emit paths mutate no cluster, so they may fail at the edge; the
   apply path below uses [run_plan_result] directly and never exits inside the
   lease. *)
let run_plan ctx ~phase ~mode plan =
  match run_plan_result ctx ~phase ~mode plan with
  | Ok rs -> rs
  | Error msg ->
    Printf.eprintf "\nerror: %s\n" msg;
    exit 1
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
let check_migration_prerequisite ~ctx ~plan ~live =
  match plan.Sol_cli_deployment_plan.profile with
  | None -> ()
  | Some _ ->
    let dir = Sol_cli_migration.default_dir in
    if not live
    then (
      (* Side-effect free: report honestly instead of creating anything. *)
      match Sol_cli_migration.required ~dir with
      | Ok [] | Error _ -> ()
      | Ok _ ->
        Printf.printf
          "Migrations: NOT verified -- a side-effect-free run creates no status Job. The \
           applied migration set is only checked against the live cluster by a real \
           deploy (before any workload moves).\n\
           %!")
    else (
      (* HARDEN-002 run 2, finding 8: this gate needs the workspace substrate --
         the application namespace and the runtime Secret -- and workload
         mutation, which used to create both, happens *after* this gate. Establish
         it here, so the gate never depends on something behind itself. Not
         workload mutation: a namespace and a Secret are not a Deployment, and
         AUDIT-069's invariant is untouched. *)
      (match
         Sol_cli_substrate.ensure
           ~ctx:ctx.execution.cluster
           ~namespaces:(Sol_cli_substrate.namespaces plan)
       with
       | Ok () -> ()
       | Error msg -> Cmd_migrate.fatal msg);
      reconcile_operator_bindings_warn
        ~ctx:ctx.execution.cluster
        ~workspace:ctx.execution.workspace;
      match
        Cmd_migrate.verify_migration_prerequisite
          ~ctx:ctx.execution.cluster
          ~target:ctx.target_name
          ~workspace:ctx.execution.workspace
          ~dir
      with
      | Cmd_migrate.No_migrations -> ()
      | Cmd_migrate.Satisfied applied ->
        Printf.printf
          "Migrations: OK -- %d declared migration(s) present in schema_migrations\n%!"
          (List.length applied)
      | Cmd_migrate.Unsatisfied missing ->
        Printf.eprintf
          "\n\
           error: the required migration set is not applied. Missing: %s\n\
          \  Migrations are workspace-wide, so this is the same set whatever scope the \
           deploy selected. Run `sol migrate apply %s`, then deploy again.\n\
           %!"
          (String.concat ", " (List.map Sol_cli_migration.to_string missing))
          ctx.target_name;
        exit 1
      | Cmd_migrate.Unavailable reason ->
        Printf.eprintf
          "\n\
           error: cannot verify the required migration state: %s\n\
          \  A deploy against the production profile fails closed rather than assume the \
           schema is compatible. Migrations are workspace-wide -- the deploy's scope \
           does not select them -- so `sol migrate apply %s` checks the same required \
           set this deploy did (it reports the applied set). Run it, then deploy again.\n\
           %!"
          reason
          ctx.target_name;
        exit 1)
;;

let run_dry_run ctx ~emit_to =
  print_header ~workspace:ctx.execution.workspace ~sha:ctx.sha ~mode_line:"(dry-run)" ();
  let plan = build_plan ctx ~emit_to in
  write_plan_if_requested ~emit_plan_to:ctx.emit_plan_to plan;
  print_planned_services plan;
  (* AUDIT-069: side-effect free, so the prerequisite is reported as not
     verified rather than checked against the cluster. *)
  check_migration_prerequisite ~ctx ~plan ~live:false;
  record_plan ctx.run_log plan;
  ignore (run_plan ctx ~phase:"dry-run" ~mode:Sol_cli_executor.Dry_run plan)
;;

let run_emit ctx ~dir =
  print_header
    ~workspace:ctx.execution.workspace
    ~sha:ctx.sha
    ~mode_line:(Printf.sprintf "emit-to: %s" dir)
    ();
  let plan = build_plan ctx ~emit_to:(Some dir) in
  write_plan_if_requested ~emit_plan_to:ctx.emit_plan_to plan;
  print_planned_services plan;
  (* AUDIT-069: emitting manifests is side-effect free for this cluster, so the
     live prerequisite is not established here. *)
  check_migration_prerequisite ~ctx ~plan ~live:false;
  record_plan ctx.run_log plan;
  let results = run_plan ctx ~phase:"emit" ~mode:(Sol_cli_executor.Emit_to dir) plan in
  List.iter
    (fun (r : Sol_cli_executor.result) ->
       let path =
         Filename.concat
           dir
           (Printf.sprintf
              "%s-%s.yaml"
              r.Sol_cli_executor.namespace
              r.Sol_cli_executor.name)
       in
       Printf.printf "  ✓  %s\n%!" path)
    results;
  Printf.printf "\nManifests written to %s/\n" dir;
  Printf.printf "Commit and push to your GitOps repo, then Argo CD will apply them.\n"
;;

let push_deploy_events
      ~ctx
      ~workspace
      ~target_cfg
      ~loki_push_url
      ~(deployment_id : Sol_cli_deployment_id.t)
      plan
  =
  let backend =
    Option.bind
      target_cfg.Sol_cli_config.observability_backend
      Sol_cli_observability_url.backend_of_string
    |> Option.value ~default:Sol_cli_observability_url.Local
  in
  let deploy_events =
    List.map
      (fun (spec : Sol_cli_deployment_plan.service_spec) ->
         { Sol_cli_deploy_event.workspace
         ; env = target_cfg.Sol_cli_config.env
         ; domain = spec.domain
         ; service = Sol_cli_kubernetes_name.k8s_name_to_string spec.k8s_name
         ; primitive = primitive_label (to_manifest_primitive spec.primitive)
         ; release_id = plan.Sol_cli_deployment_plan.release_id
         ; deployment_id
         })
      plan.Sol_cli_deployment_plan.services
  in
  try
    Cmd_deploy_event.push_all ~ctx ~backend ~explicit_url:loki_push_url deploy_events
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
  | exn ->
    Printf.eprintf
      "warning: deploy-event log push failed: %s\n%!"
      (Printexc.to_string exn)
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
         ~current:(Sol_cli_release_id.to_string plan.Sol_cli_deployment_plan.release_id)
         ~previous
     with
     | Ok [] -> ()
     | Ok pruned ->
       Printf.printf
         "Pruned %d release record(s) beyond the last %d.\n"
         (List.length pruned)
         ctx.keep_releases
     | Error msg -> Printf.eprintf "warning: could not prune old releases: %s\n%!" msg);
    Ok ()
;;

(* FEAT-074: report-only, and only for a whole-workspace deploy -- see
   cmd_up.ml's identical rationale (a scoped deploy's [plan.services] is a
   subset of the workspace, so comparing it against every live Sol-owned
   workload would false-flag out-of-scope services; a deploy never deletes,
   since it has no recorded release boundary the way [sol rollback] does).
   Best-effort -- a failure here must not fail an otherwise-successful
   deploy. *)
let report_surplus_workloads ctx (plan : Sol_cli_deployment_plan.t) =
  if String.equal ctx.requested_scope "workspace"
  then (
    match
      Sol_cli_rollback.live_workloads
        ~ctx:ctx.execution.cluster
        ~workspace:ctx.execution.workspace
    with
    | Error _ -> ()
    | Ok live ->
      let surplus = Sol_cli_rollback.unexpected_workloads ~expected:plan.services ~live in
      if surplus <> []
      then (
        Printf.printf
          "\nNote: %d live workload(s) in this workspace are not part of this deploy:\n"
          (List.length surplus);
        List.iter
          (fun ((id : Sol_cli_rollback.workload_identity), _) ->
             Printf.printf
               "  %s %s/%s\n"
               (Sol_cli_rollback.kind_resource id.kind)
               id.namespace
               id.name)
          surplus;
        Printf.printf
          "These may be stale from a removed/renamed service. 'sol rollback' prunes them \
           automatically when restoring a recorded release; delete them by hand if you \
           want them gone now.\n\
           %!"))
;;

let report_apply_success ctx plan results =
  List.iter
    (fun (r : Sol_cli_executor.result) ->
       Printf.printf
         "  ✓  namespace %s  image %s\n\n%!"
         r.Sol_cli_executor.namespace
         r.Sol_cli_executor.image)
    results;
  Printf.printf "\nDone. %d service(s) deployed.\n" (List.length ctx.services);
  print_service_urls ~ctx:ctx.execution.cluster results;
  Printf.printf "Run 'sol status' to check pod health.\n";
  report_surplus_workloads ctx plan
;;

(* FEAT-071: the Loki marker is a join key to the authoritative event, so it is
   emitted only when that event exists and the apply succeeded. *)
let push_marker_if_deployed ctx ~loki_push_url ~recorded ~deployment_id outcome plan =
  if
    recorded
    &&
    match outcome with
    | Sol_cli_deployment.Applied -> true
    | _ -> false
  then
    push_deploy_events
      ~ctx:ctx.execution.cluster
      ~workspace:ctx.execution.workspace
      ~target_cfg:ctx.target_cfg
      ~loki_push_url
      ~deployment_id
      plan
;;

(* One deploy attempt: mint the id, apply (refreshing the lease between
   workloads), derive the outcome, then record exactly one immutable event —
   success or failure — and push the marker only if that event exists and the
   apply succeeded. The release record is deliberately *not* written here: a
   failed attempt cannot claim a release exists. *)
let execute_deployment_attempt ctx ~before_apply ~loki_push_url plan =
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
  push_marker_if_deployed
    ctx
    ~loki_push_url
    ~recorded
    ~deployment_id:(Sol_cli_deployment_attempt.deployment_id attempt)
    outcome
    plan;
  Result.map (fun results -> attempt, results) applied
;;

(* The apply path, all under the workspace boundary lease. Returns a result; the
   command edge turns an [Error] into the exit, so nothing here needs [exit] (or
   the [at_exit] that used to compensate for it). *)
let run_apply ctx ~confirm_group_change ~loki_push_url =
  check_apply_environment ~services:ctx.services;
  verify_image_refs_exist ~image_refs:ctx.image_refs;
  print_header ~workspace:ctx.execution.workspace ~sha:ctx.sha ();
  let plan = build_plan ctx ~emit_to:None in
  check_consumer_group_changes
    ~ctx:ctx.execution.cluster
    ~workspace:ctx.execution.workspace
    ~confirm_group_change
    plan;
  write_plan_if_requested ~emit_plan_to:ctx.emit_plan_to plan;
  print_planned_services plan;
  (* AUDIT-069: static preflight -> live migration-status verification ->
     workload mutation. This is the last gate before the lease and any apply. *)
  check_migration_prerequisite ~ctx ~plan ~live:true;
  record_plan ctx.run_log plan;
  Sol_cli_boundary_lease.with_boundary_lease
    ~ctx:ctx.execution.cluster
    ~workspace:ctx.execution.workspace
    ~holder:Sol_cli_boundary_lease.Deploy
    ~ttl:Sol_cli_boundary_lease.default_ttl_s
    ~wait_s:0.
    (fun lease ->
       let previous = read_previous_release ctx in
       match
         execute_deployment_attempt
           ctx
           ~before_apply:(fun (_ : Sol_cli_deployment_plan.service_spec) ->
             Sol_cli_boundary_lease.ensure_held lease)
           ~loki_push_url
           plan
       with
       | Error msg -> Error msg
       | Ok (_attempt, results) ->
         (* DEC-037: record first, report second. If the authoritative release
            state cannot be written, this deploy has not succeeded, so it must
            neither print a success line nor exit zero -- and the message names
            that the workloads may already be running. *)
         Sol_cli_release.finish_deployment
           ~record_release:(fun () ->
             let ( let* ) = Result.bind in
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
                        plan.Sol_cli_deployment_plan.consumer_groups
                  }))
           ~report_success:(fun () -> report_apply_success ctx plan results))
;;

let run (req : Sol_cli_command_request.deploy_request) =
  let workspace = workspace_name () in
  let sha = req.image_tag in
  (* Resolve the scope first: a bad selector must fail before any deploy logic
     (target loading, contract check, registry resolution) can report a
     downstream cause for it. *)
  (* DEC-036: discovery once, then two different things from it. [inventory] is
     everything that exists -- what a call reference may name. [services] is the
     selection -- what this invocation deploys. They are deliberately not the same
     list, and the selection is never widened to close a call graph. *)
  let inventory = discover_services () in
  let selected =
    Sol_cli_exit.or_exit
      (Sol_cli_workload_selection.resolve_nonempty
         ~none:"no services found in app/ with a Dockerfile"
         req.scope
         inventory)
  in
  let { Sol_cli_workload_selection.requested_scope; services; _ } = selected in
  (* FEAT-050: resolve supplied artifact references against the services this
     invocation actually selected, so a name typo or an ambiguous bare
     reference fails before the target or registry is even resolved. *)
  let image_refs =
    Sol_cli_exit.or_exit
      (Sol_cli_image_ref.resolve
         ~service_names:(List.map (fun (s : Sol_cli_manifest.service) -> s.name) services)
         req.image_refs)
  in
  let resolved_config, target_cfg =
    let cfg =
      Sol_cli_exit.or_exit_with
        Sol_cli_config.error_to_string
        (Sol_cli_config.load_for_target ~target:req.target)
    in
    cfg, cfg.Sol_cli_config.target
  in
  (* sol deploy always mutates a real cluster, so unlike sol plan
     (genuinely read-only, Sol_cli_config.load_for_target's own
     permissive-overlay contract is fine for it) it needs the stronger
     guarantee that this target was deliberately declared, not just
     shaped like <env>/<provider>/<region>. A typo'd region
     (prod/aws/us-east-2 when only aws/us-east-1 is declared) would
     otherwise silently inherit sol.yml's shared defaults and apply
     anyway. sol cloud apply/destroy carry the same check for their own
     mutating action, in cmd_cloud_tf.ml's config_vars ~strict. *)
  if not (Sol_cli_config.target_declared target_cfg)
  then (
    Printf.eprintf
      "error: target %S is not declared in %s -- sol deploy requires an explicit target, \
       even an empty one, so a typo'd or unintended target can't silently inherit \
       sol.yml's shared defaults and deploy anyway.\n"
      req.target
      (Sol_cli_config.target_source target_cfg);
    exit 1);
  (* No hardcoded local-registry fallback here, deliberately: sol deploy is
     always a customer-cluster path (it never constructs
     Sol_cli_env_target.Local, unlike sol up) -- an unresolvable registry
     must reach customer_cloud_defaults's empty-registry check below and
     fail loudly, not silently point a real deploy at a k3d-only address. *)
  let registry =
    match req.registry with
    | Some r -> r
    | None ->
      (match target_cfg.Sol_cli_config.registry with
       | Some r -> r
       | None -> "")
  in
  (* DEC-041: `omit` means "not in this target's default set", so the selection the
     deploy runs on is the omit-filtered one — an omitted unit is neither deployed
     nor preflighted, by default. An explicit unit-level --scope names one back in
     (and says so); a domain-level or whole-workspace selection drops it (and says
     so). Applied here rather than in the resolver because only here is the
     resolved config known, and it is the config that declares `omit` at all. *)
  let omission =
    Sol_cli_workload_selection.apply_omission
      ~is_omitted:(fun (s : Sol_cli_manifest.service) ->
        Sol_cli_config.is_omitted_service resolved_config ~name:s.Sol_cli_manifest.name)
      selected
  in
  let unit_id (s : Sol_cli_manifest.service) = Printf.sprintf "%s/%s" s.domain s.name in
  List.iter
    (fun s ->
       Printf.printf
         "Note: %s is omitted by target %s, and --scope named it, so it is included.\n"
         (unit_id s)
         req.target)
    omission.included;
  List.iter
    (fun s ->
       Printf.printf
         "Note: %s is omitted by target %s, so it is excluded from this deploy.\n"
         (unit_id s)
         req.target)
    omission.excluded;
  (* An --image-ref naming a unit the target omits would otherwise be resolved
     against the pre-omission selection and then silently dropped: the operator
     pinned bytes for a workload and got a run without it. *)
  List.iter
    (fun (name, _) ->
       match
         List.find_opt
           (fun (s : Sol_cli_manifest.service) -> String.equal s.name name)
           omission.excluded
       with
       | None -> ()
       | Some s ->
         Printf.eprintf
           "error: --image-ref names %s, which target %s omits and this deploy excludes. \
            Name it with --scope %s to deploy it, or drop the reference.\n"
           name
           req.target
           (unit_id s);
         exit 1)
    image_refs;
  let services = omission.selected in
  (* The selection was non-empty, so an empty one here was emptied by omission --
     a different situation from a workspace with no services at all, and the
     operator's next action is different too. *)
  if services = []
  then (
    Printf.eprintf
      "error: every unit in scope is omitted by target %s: %s.\n\
      \  Name one with --scope <domain>/<name> to deploy it anyway.\n"
      req.target
      (String.concat ", " (List.map unit_id omission.excluded));
    exit 1);
  let run_log = Sol_cli_run_log.create ~prefix:"deploy" () in
  Printf.printf
    "\nRun: %s\n  log: %s/\n"
    (Sol_cli_run_log.run_id run_log)
    (Sol_cli_run_log.dir run_log);
  (* INFRA-050: resolve the secret backend once, here, where the emit intent is
     known -- not in the flag parser, and not again downstream. An explicit
     --secret-backend wins; otherwise the destination decides (a direct deploy
     writes real values, a GitOps target writes a redacted placeholder). The CLI
     used to carry its own default, which always won and made a direct deploy
     emit an empty Secret. *)
  let emit_intent =
    match req.action with
    | Sol_cli_command_request.Deploy_dry_run { emit_to } -> emit_to
    | Sol_cli_command_request.Deploy_emit_to dir -> Some dir
    | Sol_cli_command_request.Deploy_apply -> None
  in
  let secret_backend =
    match
      Sol_cli_env_target.customer_cloud_defaults
        ~registry
        ~image_tag:sha
        ~emit_to:emit_intent
        ()
    with
    | Error msg ->
      Printf.eprintf "error: %s\n%!" msg;
      exit 1
    | Ok env_target ->
      Sol_cli_env_target.resolve_secret_backend ?explicit:req.secret_backend env_target
  in
  let ctx =
    { execution =
        Sol_cli_execution.context
          ~cluster:
            (match Sol_cli_config.destination_of_target target_cfg with
             | Ok destination ->
               Sol_cli_kube_destination.context_of_destination destination
             | Error msg ->
               Printf.eprintf "error: %s\n%!" msg;
               exit 1)
          ~workspace
          ~env:target_cfg.Sol_cli_config.env
          ()
    ; sha
    ; registry
    ; secret_backend
    ; emit_plan_to = req.emit_plan_to
    ; target_cfg
    ; resolved_config
    ; services
    ; inventory
    ; image_refs
    ; requested_scope
    ; target_name = req.target
    ; run_log
    ; keep_releases = req.keep_releases
    }
  in
  match req.action with
  | Sol_cli_command_request.Deploy_dry_run { emit_to } -> run_dry_run ctx ~emit_to
  | Deploy_emit_to dir -> run_emit ctx ~dir
  | Deploy_apply ->
    (match
       run_apply
         ctx
         ~confirm_group_change:req.confirm_group_change
         ~loki_push_url:req.loki_push_url
     with
     | Ok () -> ()
     | Error msg ->
       Printf.eprintf "\nerror: %s\n" msg;
       exit 1)
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let target_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info
        []
        ~docv:"TARGET"
        ~doc:
          "Deployment target path: <env>/<provider>/<region>, e.g. dev/aws/us-east-1 — \
           same convention as 'sol plan'. Resolves sol.yml, then the environment and \
           target in sol/environments.yml, for registry/env defaults. Unlike 'sol up' \
           (local-only, no target concept), this is required.")
;;

let scope_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "scope" ]
        ~docv:"DOMAIN[/UNIT]"
        ~doc:
          "Deploy one domain (`payments`) or one unit (`payments/charge_svc`). Omit to \
           deploy the whole workspace. A name that matches nothing fails closed and says \
           what does, before the target or registry is resolved.")
;;

let dry_run_flag =
  Arg.(
    value
    & flag
    & info [ "dry-run" ] ~doc:"Print synthesized YAML to stdout without applying")
;;

let emit_to_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "emit-to" ]
        ~docv:"DIR"
        ~doc:
          "Write YAML files to DIR instead of applying (GitOps mode). One file per \
           service: <namespace>-<name>.yaml")
;;

let emit_plan_to_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "emit-plan-to" ]
        ~docv:"FILE"
        ~doc:
          "Write the deployment plan as JSON to FILE before executing. Use '-' to print \
           to stdout. Plan format is experimental.")
;;

let image_tag_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "image-tag" ]
        ~docv:"TAG"
        ~doc:
          "Image tag to deploy (default: short git SHA). In CI, pass the exact SHA built \
           by the preceding job.")
;;

let image_ref_arg =
  Arg.(
    value
    & opt_all string []
    & info
        [ "image-ref" ]
        ~docv:"[SERVICE=]REPO@sha256:DIGEST"
        ~doc:
          "Deploy a pre-built immutable artifact instead of a mutable tag. Repeatable. A \
           <service>= prefix pins one service; a bare reference requires exactly one \
           selected service. Every reference must be a digest. A target that selects \
           production-single-region requires one for every deployed workload.")
;;

let registry_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "registry" ]
        ~docv:"URL"
        ~doc:
          "Container registry prefix, e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com. \
           Omit to fall back to the resolved target's own registry (its registry in \
           sol/environments.yml); required if neither is set.")
;;

let secret_backend_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "secret-backend" ]
        ~docv:"BACKEND"
        ~doc:
          "Override how the runtime Secret is rendered. Omitted -- the usual case -- the \
           destination decides: a direct or local deploy writes real values \
           ('kubernetes-live'), while a GitOps target writes a redacted \
           'kubernetes-placeholder'. Pass 'kubernetes-placeholder' to force a redacted \
           Secret, or 'external-secrets' (with --emit-to) to emit an ExternalSecret CRD \
           for the External Secrets Operator instead.")
;;

let secret_store_ref_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "secret-store-ref" ]
        ~docv:"NAME"
        ~doc:
          "Name of the SecretStore or ClusterSecretStore to reference. Required when \
           --secret-backend=external-secrets.")
;;

let secret_store_kind_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "secret-store-kind" ]
        ~docv:"KIND"
        ~doc:
          "Kind of the secret store reference (default: ClusterSecretStore). Use \
           'SecretStore' for a namespace-scoped store.")
;;

let key_prefix_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "key-prefix" ]
        ~docv:"PREFIX"
        ~doc:
          "Prefix to prepend to each secret key when looking up in the external store \
           (default: \"\"). Example: 'myworkspace/' produces keys like \
           'myworkspace/POSTGRES_URL'.")
;;

let refresh_interval_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "refresh-interval" ]
        ~docv:"INTERVAL"
        ~doc:
          "How often ESO should sync the secret from the external store (default: 1h). \
           Examples: '1h', '30m', '5m'.")
;;

let secret_backend_term =
  let build str store_ref store_kind key_prefix refresh_interval emit_to =
    match str with
    (* INFRA-050: no flag means the *destination* decides, not the CLI. A CLI
       default here is what made a direct deploy emit an empty Secret. *)
    | None -> `Ok None
    | Some "kubernetes-placeholder" -> `Ok (Some Sol_cli_manifest.Kubernetes_placeholder)
    | Some "kubernetes-live" -> `Ok (Some Sol_cli_manifest.Kubernetes_live)
    | Some "external-secrets" when emit_to = None ->
      Printf.eprintf
        "warning: --secret-backend external-secrets is only meaningful with --emit-to; \
         using kubernetes-placeholder.\n";
      `Ok (Some Sol_cli_manifest.Kubernetes_placeholder)
    | Some "external-secrets" ->
      (match store_ref with
       | None ->
         `Error
           (true, "--secret-store-ref is required when --secret-backend=external-secrets")
       | Some sref ->
         `Ok
           (Some
              (Sol_cli_manifest.External_secrets
                 { store_ref = sref
                 ; store_kind = Option.value store_kind ~default:"ClusterSecretStore"
                 ; key_prefix = Option.value key_prefix ~default:""
                 ; refresh_interval = Option.value refresh_interval ~default:"1h"
                 })))
    | Some other ->
      `Error
        ( true
        , Printf.sprintf
            "unknown --secret-backend value %S (expected: kubernetes-live | \
             kubernetes-placeholder | external-secrets)"
            other )
  in
  Term.(
    ret
      (const build
       $ secret_backend_arg
       $ secret_store_ref_arg
       $ secret_store_kind_arg
       $ key_prefix_arg
       $ refresh_interval_arg
       $ emit_to_arg))
;;

let confirm_group_change_flag =
  Arg.(
    value
    & flag
    & info
        [ "confirm-group-change" ]
        ~doc:"Acknowledge that consumer group IDs have changed and proceed with deploy")
;;

let loki_push_url_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "loki-push-url" ]
        ~docv:"URL"
        ~doc:
          "Loki push URL for this deploy's release-event log line (OBS-037), e.g. \
           https://logs-prod-000.grafana.net. When omitted: for the \
           'local'/'self_hosted_durable' observability backends, sol deploy probes the \
           cluster for an in-cluster Loki (svc/loki -n monitoring) and, if found, \
           port-forwards to it for the duration of the push; for 'external' there is no \
           in-cluster Loki and no configured push URL, so pass this flag to record the \
           event at all. A push failure never fails the deploy.")
;;

let keep_releases_arg =
  Arg.(
    value
    & opt int Sol_cli_release_retention.default_keep
    & info
        [ "keep-releases" ]
        ~docv:"N"
        ~doc:
          (Printf.sprintf
             "Keep the last N release records after a successful deploy (default %d). \
              The current and previous release are never pruned. Deployment-event \
              history is not affected."
             Sol_cli_release_retention.default_keep))
;;

let cmd =
  Cmd.v
    (Cmd.info
       "deploy"
       ~doc:
         "Deploy pre-built images to a cluster (CI/CD integration). Like 'sol up' but \
          skips the build step — images must already be in the registry. Takes a \
          required TARGET positional (<env>/<provider>/<region>, e.g. \
          dev/aws/us-east-1), unlike 'sol up' whose positional is the optional \
          service-path filter — 'sol up' is local-only and has no target to resolve.")
    Term.(
      const
        (fun
            target
             scope
             dry_run
             emit_to
             emit_plan_to
             image_tag
             raw_image_refs
             registry
             secret_backend
             confirm_group_change
             loki_push_url
             keep_releases
           ->
           run
             (Sol_cli_exit.or_exit
                (Sol_cli_command_request.make_deploy_request
                   ~target
                   ~scope
                   ~dry_run
                   ~emit_to
                   ~emit_plan_to
                   ~image_tag
                   ~image_refs:
                     (List.map Sol_cli_image_ref.split_flag_value raw_image_refs)
                   ~registry
                   ~secret_backend
                   ~confirm_group_change
                   ~loki_push_url
                   ~keep_releases
                   ~git_sha:Sol_cli_command_request.git_sha)))
      $ target_arg
      $ scope_arg
      $ dry_run_flag
      $ emit_to_arg
      $ emit_plan_to_arg
      $ image_tag_arg
      $ image_ref_arg
      $ registry_arg
      $ secret_backend_term
      $ confirm_group_change_flag
      $ loki_push_url_arg
      $ keep_releases_arg)
;;
