open Cmdliner
open Sol_cli_manifest

(* ── Workspace / git helpers ─────────────────────────────────────────────── *)

let workspace_name () = Filename.basename (Sys.getcwd ())

let git_sha () =
  match
    Sol_cli_process.run (Sol_cli_process.cmd [ "git"; "rev-parse"; "--short"; "HEAD" ])
  with
  | Ok r when r.Sol_cli_process.exit_code = 0 && r.Sol_cli_process.stdout <> "" ->
    r.Sol_cli_process.stdout
  | _ -> "dev"
;;

let find_repo_root () =
  let rec go dir =
    if Sys.file_exists (Filename.concat dir "dune-workspace")
    then dir
    else if Sys.file_exists (Filename.concat dir "dune-project")
    then dir
    else (
      let parent = Filename.dirname dir in
      if parent = dir then dir else go parent)
  in
  go (Sys.getcwd ())
;;

(* ── Pipeline ────────────────────────────────────────────────────────────── *)

let print_header ~workspace ~sha ~dry_run =
  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  if dry_run then Printf.printf "(dry-run)\n";
  Printf.printf "\n%!"
;;

let build_plan ~requested_scope ~workspace ~sha ~services =
  match Sol_cli_up_execution.local_plan ~requested_scope ~workspace ~sha services with
  | Ok plan -> plan
  | Error err ->
    Printf.eprintf "error: %s\n" (Sol_cli_deployment_plan.plan_error_to_string err);
    exit 1
;;

let check_contract ~services =
  let findings = Sol_cli_check.run_services services in
  List.iter (fun f -> Printf.eprintf "%s\n" (Sol_cli_check.finding_to_string f)) findings;
  if Sol_cli_check.has_errors findings then exit 1
;;

(* FEAT-063: `sol up` is the local deploy path — its destination is the literal
   local cluster, named explicitly rather than inferred from ambient state. So
   there is no "is the current context the local one?" question to ask any more:
   set the local default, and let the explicit `--context` fail if the cluster
   is gone. *)
let ensure_postgres_url () =
  match Sys.getenv_opt "POSTGRES_URL" with
  | None | Some "" ->
    Unix.putenv
      "POSTGRES_URL"
      "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev"
  | Some _ -> ()
;;

let check_consumer_group_changes ~workspace ~confirm_group_change plan =
  let prev_groups =
    Sol_cli_deployment_state.load_deployed_groups
      ~ctx:Sol_cli_kube_destination.local_context
      workspace
  in
  let next_groups =
    List.map
      Sol_cli_plan_ids.Consumer_group.to_string
      plan.Sol_cli_deployment_plan.consumer_groups
  in
  let removed =
    Sol_cli_deployment_state.removed_consumer_groups ~prev:prev_groups ~next:next_groups
  in
  if removed <> [] && not confirm_group_change
  then (
    Printf.eprintf
      "\n\
       warning: the following consumer group(s) are no longer present in this deploy plan:\n";
    List.iter (fun g -> Printf.eprintf "  - %s\n" g) removed;
    Printf.eprintf
      "\n\
       Messages produced while the old group is absent will be consumed\n\
       from the latest offset when the group is re-added, silently skipping\n\
       any backlog.  Pass --confirm-group-change to acknowledge and proceed.\n\n";
    exit 1)
;;

let prepare_context ~repo_root =
  Printf.printf "Preparing build context...\n%!";
  match Sol_cli_up_execution.prepare_build_context ~repo_root with
  | Ok ctx_dir -> Ok ctx_dir
  | Error msg -> Error msg
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
  match
    Sol_cli_up_execution.apply_service_manifest
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace
      ~release_id
      ~dry_run:true
      (Sol_cli_up_execution.dry_run_spec ~workspace ~sha spec)
  with
  | Ok _ -> ()
  | Error msg -> raise (Deploy_failed msg)
;;

let apply_service
      ~workspace
      ~ctx_dir
      ~sha
      ~pf_failed
      ~release_id
      (spec : Sol_cli_deployment_plan.service_spec)
  =
  let exec = Sol_cli_up_execution.service_execution ~workspace ~ctx_dir ~sha spec in
  print_service_start spec;
  Printf.printf "  packaging %s...\n%!" exec.push_image;
  (match Sol_cli_up_execution.build_image exec with
   | Error msg -> raise (Deploy_failed msg)
   | Ok () -> ());
  Printf.printf "  pushing...\n%!";
  (match Sol_cli_up_execution.push_image exec with
   | Error msg -> raise (Deploy_failed msg)
   | Ok () -> ());
  (match
     Sol_cli_up_execution.apply_service_manifest
       ~ctx:Sol_cli_kube_destination.local_context
       ~workspace
       ~release_id
       ~dry_run:false
       spec
   with
   | Ok _ -> ()
   | Error msg -> raise (Deploy_failed msg));
  (match spec.primitive with
   | Sol_cli_deployment_plan.Fn -> ()
   | Sol_cli_deployment_plan.Svc | Sol_cli_deployment_plan.Worker ->
     Printf.printf "  waiting for rollout...\n%!";
     (match
        Sol_cli_up_execution.wait_for_service_rollout
          ~ctx:Sol_cli_kube_destination.local_context
          spec
          exec
      with
      | Ok () -> ()
      | Error msg -> raise (Deploy_failed msg)));
  match spec.primitive with
  | Sol_cli_deployment_plan.Svc ->
    let local_port = 8080 in
    (* FRIC-025: key port-forward state by namespace+service, not by service name
       alone. Two workspaces both expose a `charge-svc`, so the old key made their
       pid/log/script files collide on disk (and made `is_running` report the other
       workspace's forward) independently of the :8080 bind conflict. *)
    let pf_name = Printf.sprintf "%s-%s" exec.namespace exec.k8s_name in
    if not (Sol_cli_port_forward.is_running pf_name)
    then (
      if
        Sol_cli_port_forward.detect_stale
          ~local_port
          ~namespace:exec.namespace
          ~target:("svc/" ^ exec.k8s_name)
      then Unix.sleepf 0.4;
      Sol_cli_port_forward.start
        ~ctx:Sol_cli_kube_destination.local_context
        { name = pf_name
        ; namespace = exec.namespace
        ; target = "svc/" ^ exec.k8s_name
        ; local_port
        ; remote_port = 80
        });
    let pf_alive = Sol_cli_port_forward.check_alive ~name:pf_name ~local_port in
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

let record_plan run_log plan =
  Sol_cli_run_log.append_phase_log
    run_log
    ~phase:"plan"
    (Format.asprintf "%a" Sol_cli_deployment_plan.pp_summary plan)
;;

let run_dry_run ~run_log ~requested_scope ~workspace ~sha ~services =
  print_header ~workspace ~sha ~dry_run:true;
  let plan = build_plan ~requested_scope ~workspace ~sha ~services in
  record_plan run_log plan;
  match
    Sol_cli_run_log.run_task run_log ~name:"dry-run" (fun () ->
      try
        List.iter
          (dry_run_service
             ~workspace
             ~sha
             ~release_id:plan.Sol_cli_deployment_plan.release_id)
          plan.Sol_cli_deployment_plan.services;
        Ok ()
      with
      | Deploy_failed msg -> Error msg)
  with
  | Ok () -> ()
  | Error msg ->
    Printf.eprintf "\nerror: %s\n" msg;
    exit 1
;;

let run_apply
      ~run_log
      ~requested_scope
      ~workspace
      ~sha
      ~services
      ~repo_root
      ~confirm_group_change
  =
  check_contract ~services;
  ensure_postgres_url ();
  print_header ~workspace ~sha ~dry_run:false;
  let plan = build_plan ~requested_scope ~workspace ~sha ~services in
  check_consumer_group_changes ~workspace ~confirm_group_change plan;
  record_plan run_log plan;
  let pf_failed = ref false in
  (* FEAT-071: the attempt starts here — mint its id before the apply, then
     record the immutable event once, when the attempt finishes. *)
  let now = Unix.gettimeofday () in
  let deployment_id =
    Sol_cli_deployment_id.create ~now ~entropy:(Sol_cli_deployment_id.random_entropy ())
  in
  let applied =
    match
      Sol_cli_run_log.run_task run_log ~name:"apply" (fun () ->
        match prepare_context ~repo_root with
        | Error msg -> Error msg
        | Ok ctx_dir ->
          (try
             List.iter
               (apply_service
                  ~workspace
                  ~ctx_dir
                  ~sha
                  ~pf_failed
                  ~release_id:plan.Sol_cli_deployment_plan.release_id)
               plan.Sol_cli_deployment_plan.services;
             Sol_cli_up_execution.remove_build_context ~ctx_dir;
             Ok ()
           with
           | Deploy_failed msg ->
             Sol_cli_up_execution.remove_build_context ~ctx_dir;
             Error msg))
    with
    | Ok () ->
      let summary = Sol_cli_up_execution.post_deploy_summary ~cwd:(Sys.getcwd ()) plan in
      Printf.printf "Done. %d service(s) deployed.\n" summary.deployed_count;
      Printf.printf "Run 'sol local status' to check pod health.\n";
      if summary.pending_migrations > 0
      then
        Printf.printf
          "\n\
           Note: %d migration file(s) found in db/migrations/ — run 'sol migrate' to \
           apply.\n"
          summary.pending_migrations;
      Sol_cli_up_execution.record_applied
        ~ctx:Sol_cli_kube_destination.local_context
        ~workspace
        ~sha
        plan;
      (* The release record is only written when the apply succeeded: "the
         release exists / was applied" is a claim a failed attempt cannot make. *)
      (match
         Sol_cli_release_store.record_plan
           ~ctx:Sol_cli_kube_destination.local_context
           ~apply_mode:Sol_cli_release.Direct
           plan
       with
       | Ok () -> ()
       | Error msg -> Printf.eprintf "warning: could not record release: %s\n%!" msg);
      Ok ()
    | Error msg -> Error msg
  in
  let outcome =
    match applied with
    | Ok () -> Sol_cli_deployment.Applied
    | Error _ -> Sol_cli_deployment.Apply_failed
  in
  (* FEAT-070: `sol up` is a deployment too, so it records the event as well —
     non-fatal like the release record, and the release path above is untouched. *)
  (match
     Sol_cli_deployment_store.record
       ~ctx:Sol_cli_kube_destination.local_context
       (Sol_cli_deployment.of_plan
          ~deployment_id
          ~now
          ~git_commit:(Sol_cli_deployment.git_commit ())
          ~git_dirty:(Sol_cli_deployment.git_dirty ())
          ~actor:(Sys.getenv_opt "SOL_ACTOR")
          ~target:(Some "local")
          ~outcome
          plan)
   with
   | Ok () -> ()
   | Error msg -> Printf.eprintf "warning: could not record deployment: %s\n%!" msg);
  match applied with
  | Ok () -> if !pf_failed then exit 1
  | Error msg ->
    Printf.eprintf "\nerror: %s\n" msg;
    exit 1
;;

let run (req : Sol_cli_command_request.up_request) =
  let workspace = workspace_name () in
  let sha = req.image_tag in
  let selected =
    match Sol_cli_workload_selection.resolve req.scope (discover_services ()) with
    | Ok selected -> selected
    | Error message ->
      Printf.eprintf "error: %s\n" message;
      exit 1
  in
  let requested_scope = Sol_cli_deployment_scope.request_to_string selected.request in
  let services = selected.Sol_cli_workload_selection.services in
  (* Mutating command: an empty selection is an error, never a silent success.
     [resolve] only yields empty for a whole-workspace request over nothing, so
     the message names that case rather than the scope. *)
  if services = []
  then (
    Printf.eprintf "No services found in app/ with a Dockerfile.\n";
    exit 1);
  let run_log = Sol_cli_run_log.create ~prefix:"up" () in
  Printf.printf
    "\nRun: %s\n  log: %s/\n"
    (Sol_cli_run_log.run_id run_log)
    (Sol_cli_run_log.dir run_log);
  match req.mode with
  | Sol_cli_command_request.Dry_run ->
    run_dry_run ~run_log ~requested_scope ~workspace ~sha ~services
  | Apply ->
    let repo_root = find_repo_root () in
    run_apply
      ~run_log
      ~requested_scope
      ~workspace
      ~sha
      ~services
      ~repo_root
      ~confirm_group_change:req.confirm_group_change
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let scope_arg =
  Arg.(
    value
    & opt (some string) None
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
    & opt (some string) None
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

let cmd =
  Cmd.v
    (Cmd.info
       "up"
       ~doc:
         "Build images, synthesize k8s manifests, and deploy to the local cluster. \
          Local-only — no target concept, unlike 'sol deploy'.")
    Term.(
      const (fun scope dry_run tag confirm_group_change ->
        match
          Sol_cli_command_request.make_up_request
            ~scope
            ~dry_run
            ~tag
            ~confirm_group_change
            ~git_sha
        with
        | Ok req -> run req
        | Error msg ->
          Printf.eprintf "error: %s\n" msg;
          exit 1)
      $ scope_arg
      $ dry_run_flag
      $ tag_arg
      $ confirm_group_change_flag)
;;
