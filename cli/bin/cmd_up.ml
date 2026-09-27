open Cmdliner
open Sol_cli_manifest
open Result.Syntax

(* ── Pipeline ────────────────────────────────────────────────────────────── *)

let print_header ~workspace ~sha ~dry_run =
  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  if dry_run then Printf.printf "(dry-run)\n";
  Printf.printf "\n%!"
;;

let build_plan ~requested_scope ~workspace ~sha ~facts ~services =
  Sol_cli_up_execution.local_plan ~requested_scope ~workspace ~sha ~facts services
  |> Sol_cli_exit.of_error Sol_cli_deployment_plan.plan_error_to_string
;;

let check_contract ~facts ~services =
  let findings = Sol_cli_check.run_services ~facts services in
  findings
  |> List.iter (fun f -> Printf.eprintf "%s\n" (Sol_cli_check.finding_to_string f));
  if Sol_cli_check.has_errors findings then Error (Sol_cli_exit.reported ()) else Ok ()
;;

(* FEAT-063: `sol up` is the local deploy path — its destination is the literal
   local cluster, named explicitly rather than inferred from ambient state. So
   there is no "is the current context the local one?" question to ask any more:
   set the local default, and let the explicit `--context` fail if the cluster
   is gone. *)
let ensure_postgres_url () =
  match Sol_cli_string.env "POSTGRES_URL" with
  | None ->
    Unix.putenv
      "POSTGRES_URL"
      "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev"
  | Some _ -> ()
;;

let check_consumer_group_changes ~workspace ~confirm_group_change plan =
  match
    Sol_cli_deployment_state.check_removed_groups
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace
      ~confirm_group_change
      ~next:
        (List.map
           Sol_cli_plan_ids.Consumer_group.to_string
           plan.Sol_cli_deployment_plan.consumer_groups)
  with
  | Ok () -> Ok ()
  | Error msg -> Error (Sol_cli_exit.failure msg)
;;

let prepare_context ~repo_root =
  Printf.printf "Preparing build context...\n%!";
  Sol_cli_up_execution.prepare_build_context ~repo_root
;;

let to_manifest_primitive = Sol_cli_up_execution.manifest_primitive

let print_service_start spec =
  Printf.printf
    "[%s] %s/%s\n%!"
    (primitive_label (to_manifest_primitive spec.Sol_cli_deployment_plan.primitive))
    spec.domain
    spec.source_name
;;

let dry_run_service
      ~workspace
      ~sha
      ~release_id
      (spec : Sol_cli_deployment_plan.service_spec)
  =
  print_service_start spec;
  Sol_cli_up_execution.apply_service_manifest
    ~ctx:Sol_cli_kube_destination.local_context
    ~workspace
    ~release_id
    ~dry_run:true
    (Sol_cli_up_execution.dry_run_spec ~workspace ~sha spec)
  |> Result.map ignore
;;

(* Build, push, apply and wait: the steps whose failure fails the run. *)
let deploy_service
      ~workspace
      ~ctx_dir
      ~sha
      ~release_id
      (spec : Sol_cli_deployment_plan.service_spec)
  =
  let exec = Sol_cli_up_execution.service_execution ~workspace ~ctx_dir ~sha spec in
  print_service_start spec;
  Printf.printf "  packaging %s...\n%!" exec.push_image;
  let* () = Sol_cli_up_execution.build_image exec in
  Printf.printf "  pushing...\n%!";
  let* () = Sol_cli_up_execution.push_image exec in
  let* _ =
    Sol_cli_up_execution.apply_service_manifest
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace
      ~release_id
      ~dry_run:false
      spec
  in
  let* () =
    match spec.primitive with
    | Sol_cli_deployment_plan.Fn -> Ok ()
    | Sol_cli_deployment_plan.Svc | Sol_cli_deployment_plan.Worker ->
      Printf.printf "  waiting for rollout...\n%!";
      Sol_cli_up_execution.wait_for_service_rollout
        ~ctx:Sol_cli_kube_destination.local_context
        spec
        exec
  in
  Ok exec
;;

(* Reach a deployed -svc from the host. A failed port-forward is reported and
   noted in [pf_failed]; it does not fail the release that was applied. *)
let expose_service
      ~pf_failed
      (spec : Sol_cli_deployment_plan.service_spec)
      (exec : Sol_cli_up_execution.service_execution)
  =
  match spec.primitive with
  | Sol_cli_deployment_plan.Svc ->
    let local_port = 8080 in
    (* FRIC-025: key port-forward state by namespace+service, not by service name
       alone. Two workspaces both expose a `charge-svc`, so the old key made their
       pid/log/script files collide on disk (and made `is_running` report the other
       workspace's forward) independently of the :8080 bind conflict. *)
    let pf_name = Printf.sprintf "%s-%s" exec.namespace exec.k8s_name in
    let target = "svc/" ^ exec.k8s_name in
    if not (Sol_cli_port_forward.is_running pf_name)
    then (
      let replaced =
        Sol_cli_port_forward.replace_conflicting
          ~local_port
          ~namespace:exec.namespace
          ~target
      in
      replaced
      |> List.iter (fun (old : Sol_cli_port_forward.spec) ->
        Printf.printf
          "  [sol up] replacing stale port-forward for %s/%s on port %d\n%!"
          old.namespace
          old.target
          local_port);
      if replaced <> [] then Unix.sleepf 0.4;
      Sol_cli_port_forward.start
        ~ctx:Sol_cli_kube_destination.local_context
        { name = pf_name
        ; namespace = exec.namespace
        ; target
        ; local_port
        ; remote_port = 80
        }
      |> Result.iter_error (Printf.eprintf "  warning: port-forward not started: %s\n%!"));
    let pf_alive =
      match Sol_cli_port_forward.check_alive ~name:pf_name with
      | Alive -> true
      | Dead { log; log_tail } ->
        Printf.printf
          "  warning: port-forward for %s failed (port %d may be in use by another \
           workspace).\n"
          pf_name
          local_port;
        Printf.printf "           See %s for details.\n" log;
        if log_tail <> []
        then
          Printf.printf
            "           Last log lines:\n             %s\n"
            (String.concat "\n             " log_tail);
        Printf.printf "           Run: kill $(lsof -ti:%d) && sol up\n%!" local_port;
        false
    in
    Printf.printf "  ✓  namespace %s  image %s\n%!" exec.namespace spec.image;
    if pf_alive
    then
      Printf.printf
        "  →  http://localhost:%d  (port-forward running in background)\n\n%!"
        local_port
    else (
      pf_failed := true;
      Printf.printf "\n%!")
  | _ ->
    Printf.printf "  ✓  namespace %s  image %s\n%!" exec.namespace spec.image;
    Printf.printf "\n%!"
;;

let apply_service ~workspace ~ctx_dir ~sha ~pf_failed ~release_id spec =
  let* exec = deploy_service ~workspace ~ctx_dir ~sha ~release_id spec in
  expose_service ~pf_failed spec exec;
  Ok ()
;;

let record_plan run_log plan =
  Sol_cli_run_log.append_phase_log
    run_log
    ~phase:"plan"
    (Format.asprintf "%a" Sol_cli_deployment_plan.pp_summary plan)
;;

(* REFAC-112: the preamble both modes share, so neither can drift from the other. *)
let prepare_plan ~run_log ~dry_run ~requested_scope ~workspace ~sha ~facts ~services =
  print_header ~workspace ~sha ~dry_run;
  let* plan = build_plan ~requested_scope ~workspace ~sha ~facts ~services in
  record_plan run_log plan;
  Ok plan
;;

(* A failed run's message stands apart from the progress output above it. *)
let run_failed msg = Sol_cli_exit.failure ("\nerror: " ^ msg)

let run_dry_run ~run_log ~requested_scope ~workspace ~sha ~facts ~services =
  let* plan =
    prepare_plan ~run_log ~dry_run:true ~requested_scope ~workspace ~sha ~facts ~services
  in
  Result.map_error run_failed
  @@ Sol_cli_run_log.run_task run_log ~name:"dry-run" (fun () ->
    plan.services
    |> List.fold_left
         (fun acc spec ->
            let* () = acc in
            dry_run_service ~workspace ~sha ~release_id:plan.release_id spec)
         (Ok ()))
;;

(* `sol up` is a deploy of the local cluster, so these mirror cmd_deploy's
   helpers but always target the local destination. *)
let cluster = Sol_cli_kube_destination.local_context

(* Three-valued, for the same reason as cmd_deploy.ml's twin: this value is
   retention's "protect the previous release" input, so a failed read must not
   become "no previous release" (FND-0025). *)
let read_previous_release ~workspace =
  match Sol_cli_release_store.current ~ctx:cluster ~workspace with
  | Ok (Some release_id) -> Sol_cli_release_retention.Known release_id
  | Ok None -> Sol_cli_release_retention.None_yet
  | Error msg -> Sol_cli_release_retention.Unreadable msg
;;

(* DEC-037: see cmd_deploy.ml's twin. The release state is part of the outcome of
   a deployment, not bookkeeping after it, so a failure to write it fails the
   deployment. Pruning stays best-effort. *)
let record_release_and_prune ~workspace ~keep ~previous plan =
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
         ~keep
         ~current:(Sol_cli_release_id.to_string plan.release_id)
         ~previous
     with
     | Ok [] -> ()
     | Ok pruned ->
       Printf.printf
         "Pruned %d release record(s) beyond the last %d.\n"
         (List.length pruned)
         keep
     | Error msg -> Printf.eprintf "warning: could not prune old releases: %s\n%!" msg);
    Ok ()
;;

(* Build the image context and apply every workload, refreshing the lease
   between workloads and stopping cleanly if a rollback asks this up to abort.
   Returns a result; a failed port-forward is tracked separately in [pf_failed]
   because it does not invalidate the release that was applied. *)
let apply_plan ~run_log ~workspace ~sha ~repo_root ~pf_failed ~lease plan =
  Sol_cli_run_log.run_task run_log ~name:"apply" (fun () ->
    match prepare_context ~repo_root with
    | Error msg -> Error msg
    | Ok ctx_dir ->
      (* Stops at the first service that fails; the build context goes either way. *)
      let applied =
        plan.services
        |> List.fold_left
             (fun acc spec ->
                let* () = acc in
                let* () = Sol_cli_boundary_lease.ensure_held lease in
                apply_service
                  ~workspace
                  ~ctx_dir
                  ~sha
                  ~pf_failed
                  ~release_id:plan.Sol_cli_deployment_plan.release_id
                  spec)
             (Ok ())
      in
      Sol_cli_up_execution.remove_build_context ~ctx_dir;
      applied)
;;

(* FEAT-074: report-only, and only for a whole-workspace deploy -- a scoped
   deploy's [plan.services] is a subset of the workspace, so comparing it
   against every live Sol-owned workload would flag out-of-scope services as
   false surplus. Never deletes: unlike [sol rollback], a deploy has no
   recorded release boundary backing the claim "this is exactly what should
   exist", only what it was asked to deploy this run. Best-effort -- a
   failure here must not fail an otherwise-successful deploy. *)
let report_surplus_workloads ~workspace (plan : Sol_cli_deployment_plan.t) =
  if String.equal plan.requested_scope "workspace"
  then (
    match Sol_cli_rollback.live_workloads ~ctx:cluster ~workspace with
    | Error _ -> ()
    | Ok live ->
      let surplus = Sol_cli_rollback.unexpected_workloads ~expected:plan.services ~live in
      if surplus <> []
      then (
        Printf.printf
          "\nNote: %d live workload(s) in this workspace are not part of this deploy:\n"
          (List.length surplus);
        surplus
        |> List.iter (fun ((id : Sol_cli_rollback.workload_identity), _) ->
          Printf.printf
            "  %s %s/%s\n"
            (Sol_cli_rollback.kind_resource id.kind)
            id.namespace
            id.name);
        Printf.printf
          "These may be stale from a removed/renamed service. 'sol rollback' prunes them \
           automatically when restoring a recorded release; delete them by hand if you \
           want them gone now.\n\
           %!"))
;;

let report_apply_success ~workspace ~facts plan =
  let summary = Sol_cli_up_execution.post_deploy_summary ~facts plan in
  Printf.printf "Done. %d service(s) deployed.\n" summary.deployed_count;
  Printf.printf "Run 'sol local status' to check pod health.\n";
  if summary.pending_migrations > 0
  then
    Printf.printf
      "\n\
       Note: %d migration file(s) found in db/migrations/ — run 'sol migrate' to apply.\n"
      summary.pending_migrations;
  report_surplus_workloads ~workspace plan
;;

(* The apply path, under the workspace boundary lease. Returns a result; the
   command edge turns [Error] into the exit, so nothing here exits. *)
let run_apply
      ~run_log
      ~requested_scope
      ~workspace
      ~sha
      ~facts
      ~services
      ~repo_root
      ~confirm_group_change
      ~keep_releases
  =
  let* () = check_contract ~facts ~services in
  ensure_postgres_url ();
  let* plan =
    prepare_plan ~run_log ~dry_run:false ~requested_scope ~workspace ~sha ~facts ~services
  in
  let* () = check_consumer_group_changes ~workspace ~confirm_group_change plan in
  let pf_failed = ref false in
  let result =
    Sol_cli_boundary_lease.with_boundary_lease
      ~ctx:cluster
      ~workspace
      ~holder:Sol_cli_boundary_lease.Deploy
      ~ttl:Sol_cli_boundary_lease.default_ttl_s
      ~wait_s:0.
      (fun lease ->
         let previous = read_previous_release ~workspace in
         let attempt = Sol_cli_deployment_attempt.start () in
         let applied =
           apply_plan ~run_log ~workspace ~sha ~repo_root ~pf_failed ~lease plan
         in
         ignore
           (Sol_cli_deployment_attempt.record
              ~ctx:cluster
              ~target:(Some "local")
              plan
              attempt
              (Sol_cli_deployment_attempt.outcome_of applied));
         match applied with
         | Error msg -> Error msg
         | Ok () ->
           (* DEC-037: record before reporting success. *)
           Sol_cli_release.finish_deployment
             ~record_release:(fun () ->
               let* () =
                 record_release_and_prune ~workspace ~keep:keep_releases ~previous plan
               in
               (* BUG-045: the next deploy's consumer-group guard reads this record,
                  so failing to write it is a failure, reported before "Done". *)
               Sol_cli_up_execution.record_applied ~ctx:cluster ~workspace ~sha plan)
             ~report_success:(fun () -> report_apply_success ~workspace ~facts plan))
  in
  Result.map_error run_failed
  @@
  match result with
  | Error msg -> Error msg
  | Ok () -> if !pf_failed then Error "one or more port-forwards failed" else Ok ()
;;

let run (req : Sol_cli_command_request.up_request) =
  (* DEC-024: enter the workspace (the nearest ancestor with a sol.yml) from any
     descendant directory; a missing or nested boundary fails closed (BUG-034). *)
  let* { root = repo_root; name = workspace } = Sol_cli_workspace.enter_cwd () in
  let sha = req.image_tag in
  (* REFAC-130: the workspace is read once, here, and everything below projects
     it: the inventory, the plan's topics/migrations/schema subjects, the
     contract check, and the pending-migration count. *)
  let* facts = Sol_cli_workspace_model.load ~root:repo_root |> Sol_cli_exit.of_msg in
  let inventory = Sol_cli_workspace_model.services facts in
  (* Mutating command: an empty selection is an error, never a silent success. *)
  let* { requested_scope; services; _ } =
    Sol_cli_workload_selection.resolve_nonempty
      ~none:"no services found in app/ with a Dockerfile"
      req.scope
      inventory
    |> Sol_cli_exit.of_msg
  in
  let run_log = Sol_cli_run_log.create ~prefix:"up" () in
  Printf.printf
    "\nRun: %s\n  log: %s/\n"
    (Sol_cli_run_log.run_id run_log)
    (Sol_cli_run_log.dir run_log);
  match req.mode with
  | Sol_cli_command_request.Dry_run ->
    run_dry_run ~run_log ~requested_scope ~workspace ~sha ~facts ~services
  | Apply ->
    run_apply
      ~run_log
      ~requested_scope
      ~workspace
      ~sha
      ~facts
      ~services
      ~repo_root
      ~confirm_group_change:req.confirm_group_change
      ~keep_releases:req.keep_releases
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let scope_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "scope" ]
        ~docv:"DOMAIN[/UNIT]"
        ~doc:
          "Build and deploy one domain (`payments`) or one unit (`payments/charge_svc`). \
           Omit to deploy the whole workspace. A name that matches nothing fails closed \
           and says what does, before any image is built.")
;;

let dry_run_flag =
  Arg.(
    value
    & flag
    & info
        [ "dry-run" ]
        ~doc:"Print synthesized YAML to stdout without applying to the cluster")
;;

let tag_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info [ "tag" ] ~docv:"TAG" ~doc:"Docker image tag (default: short git SHA)")
;;

let confirm_group_change_flag =
  Arg.(
    value
    & flag
    & info
        [ "confirm-group-change" ]
        ~doc:"Acknowledge that consumer group IDs have changed and proceed with deploy")
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
       "up"
       ~doc:
         "Build images, synthesize k8s manifests, and deploy to the local cluster. \
          Local-only — no target concept, unlike 'sol deploy'.")
    Term.(
      const (fun scope dry_run tag confirm_group_change keep_releases ->
        Sol_cli_exit.exit_on
          (let* req =
             Sol_cli_command_request.make_up_request
               ~scope
               ~dry_run
               ~tag
               ~confirm_group_change
               ~keep_releases
               ~git_sha:Sol_cli_command_request.git_sha
             |> Sol_cli_exit.of_msg
           in
           Option.iter (Printf.eprintf "warning: %s\n") req.image_tag_warning;
           run req))
      $ scope_arg
      $ dry_run_flag
      $ tag_arg
      $ confirm_group_change_flag
      $ keep_releases_arg)
;;
