open Cmdliner
open Sol_cli_manifest

let wait_for_rollout ~namespace ~name =
  match Sol_cli_kubectl.rollout_status
          ~kind_name:("deployment/" ^ name) ~namespace with
  | Ok r -> r.Sol_cli_process.exit_code
  | Error _ -> 1

(* ── Workspace / git helpers ─────────────────────────────────────────────── *)

let workspace_name () = Filename.basename (Sys.getcwd ())

let git_sha () =
  match Sol_cli_process.run (Sol_cli_process.cmd ["git"; "rev-parse"; "--short"; "HEAD"]) with
  | Ok r when r.Sol_cli_process.exit_code = 0 && r.Sol_cli_process.stdout <> "" ->
    r.Sol_cli_process.stdout
  | _ -> "dev"

let current_kube_context () =
  match Sol_cli_kubectl.config_current_context () with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> r.Sol_cli_process.stdout
  | _ -> ""

let is_known_local_dev_context () =
  current_kube_context () = "k3d-sol-local"

let find_repo_root () =
  let rec go dir =
    if Sys.file_exists (Filename.concat dir "dune-workspace") then dir
    else if Sys.file_exists (Filename.concat dir "dune-project") then dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then dir
      else go parent
  in
  go (Sys.getcwd ())

(* ── Pipeline ────────────────────────────────────────────────────────────── *)

let print_header ~workspace ~sha ~dry_run =
  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  if dry_run then Printf.printf "(dry-run)\n";
  Printf.printf "\n%!"

let build_plan ~workspace ~services ~env =
  match Sol_cli_deployment_plan.of_services_result ~workspace ~env services with
  | Ok plan -> plan
  | Error err ->
    Printf.eprintf "error: %s\n" (Sol_cli_deployment_plan.plan_error_to_string err);
    exit 1

let check_contract ~filter_path =
  let findings = Sol_cli_check.run ~filter_path () in
  List.iter (fun f -> Printf.eprintf "%s\n" (Sol_cli_check.finding_to_string f)) findings;
  if Sol_cli_check.has_errors findings then exit 1

let ensure_postgres_url () =
  if is_known_local_dev_context () then begin
    match Sys.getenv_opt "POSTGRES_URL" with
    | None | Some "" ->
      Unix.putenv "POSTGRES_URL"
        "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev"
    | Some _ -> ()
  end else begin
    match Sys.getenv_opt "POSTGRES_URL" with
    | None | Some "" ->
      Printf.eprintf
        "error: POSTGRES_URL is not set.\n\
         Set it in your environment before running 'sol up':\n\
         \  export POSTGRES_URL=postgresql://user:pass@host:5432/dbname\n";
      exit 1
    | Some _ -> ()
  end

let check_consumer_group_changes ~workspace ~confirm_group_change plan =
  let prev_groups = Sol_cli_deployment_state.load_deployed_groups workspace in
  let next_groups = List.map Sol_cli_plan_ids.Consumer_group.to_string
                      plan.Sol_cli_deployment_plan.consumer_groups in
  let removed = Sol_cli_deployment_state.removed_consumer_groups ~prev:prev_groups ~next:next_groups in
  if removed <> [] && not confirm_group_change then begin
    Printf.eprintf
      "\nwarning: the following consumer group(s) are no longer present in \
       this deploy plan:\n";
    List.iter (fun g -> Printf.eprintf "  - %s\n" g) removed;
    Printf.eprintf
      "\nMessages produced while the old group is absent will be consumed\n\
       from the latest offset when the group is re-added, silently skipping\n\
       any backlog.  Pass --confirm-group-change to acknowledge and proceed.\n\n";
    exit 1
  end

let prepare_context ~repo_root ~ctx_dir =
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
  Printf.printf "Preparing build context...\n%!";
  let rsync_cmd = Printf.sprintf
    "rsync -a --copy-links --exclude='_build' --exclude='.git' %s/ %s"
    (Filename.quote repo_root) (Filename.quote ctx_dir) in
  if Sys.command rsync_cmd <> 0 then begin
    Printf.eprintf "error: failed to copy workspace for docker build context\n";
    exit 1
  end

let to_manifest_primitive = function
  | Sol_cli_deployment_plan.Svc    -> Svc
  | Sol_cli_deployment_plan.Worker -> Worker
  | Sol_cli_deployment_plan.Fn     -> Fn

let print_service_start spec =
  Printf.printf "[%s] %s/%s\n%!"
    (primitive_label (to_manifest_primitive spec.Sol_cli_deployment_plan.primitive))
    spec.domain spec.source_name

let dry_run_service ~workspace ~push_registry ~sha
    (spec : Sol_cli_deployment_plan.service_spec) =
  let push_image = Sol_cli_deployment_plan.image_ref
    ~registry:push_registry ~workspace
    ~k8s_name:spec.k8s_name ~tag:sha in
  print_service_start spec;
  ignore (Sol_cli_executor.local ~workspace ~dry_run:true
    { spec with Sol_cli_deployment_plan.image = push_image })

let apply_service ~workspace ~ctx_dir ~push_registry ~sha ~pf_failed
    (spec : Sol_cli_deployment_plan.service_spec) =
  let k8s_name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
  let namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace in
  let push_image = Sol_cli_deployment_plan.image_ref
    ~registry:push_registry ~workspace
    ~k8s_name:spec.k8s_name ~tag:sha in
  let dockerfile = Printf.sprintf "%s/%s/Dockerfile" ctx_dir spec.source_dir in

  print_service_start spec;
  Printf.printf "  packaging %s...\n%!" push_image;
  (match Sol_cli_docker.build ~tag:push_image ~dockerfile ~context:ctx_dir with
   | Error e ->
     raise (Deploy_failed (Printf.sprintf "docker build failed: %s\n%s"
       spec.source_dir (Sol_cli_process.error_to_string e)))
   | Ok () -> ());
  Printf.printf "  pushing...\n%!";
  (match Sol_cli_docker.push ~image_ref:push_image with
   | Error e ->
     raise (Deploy_failed (Printf.sprintf "docker push failed: %s\n%s"
       push_image (Sol_cli_process.error_to_string e)))
   | Ok () -> ());

  ignore (Sol_cli_executor.local ~workspace ~dry_run:false spec);

  (match spec.primitive with
   | Sol_cli_deployment_plan.Svc
   | Sol_cli_deployment_plan.Worker ->
     Printf.printf "  waiting for rollout...\n%!";
     if wait_for_rollout ~namespace ~name:k8s_name <> 0 then begin
       let pod_expectation =
         Sol_cli_status.pod_expectation_of_primitive (to_manifest_primitive spec.primitive)
       in
       let diagnosis =
         Sol_cli_rollout_diagnosis.diagnose_service_live
           ~pod_expectation ~ns:namespace ~service_name:spec.source_name
           ~k8s_name ()
       in
       raise (Deploy_failed (match diagnosis with
         | Some d -> d
         | None   -> Printf.sprintf "rollout failed: %s/%s" namespace k8s_name))
     end
   | Sol_cli_deployment_plan.Fn -> ());
  (match spec.primitive with
   | Sol_cli_deployment_plan.Svc ->
     let local_port = 8080 in
     if not (Sol_cli_port_forward.is_running k8s_name) then begin
       if Sol_cli_port_forward.detect_stale ~local_port
            ~namespace ~target:("svc/" ^ k8s_name)
       then Unix.sleepf 0.4;
       Sol_cli_port_forward.start {
         name        = k8s_name;
         namespace;
         target      = "svc/" ^ k8s_name;
         local_port;
         remote_port = 80;
       }
     end;
     let pf_alive = Sol_cli_port_forward.check_alive ~name:k8s_name ~local_port in
     Printf.printf "  ✓  namespace %s  image %s\n%!" namespace spec.image;
     if pf_alive then
       Printf.printf "  →  http://localhost:%d  (port-forward running in background)\n\n%!" local_port
     else begin
       pf_failed := true;
       Printf.printf "\n%!"
     end
   | _ ->
     Printf.printf "  ✓  namespace %s  image %s\n%!" namespace spec.image;
     Printf.printf "\n%!")

let run_dry_run ~workspace ~sha ~services =
  print_header ~workspace ~sha ~dry_run:true;
  let env_target = Sol_cli_env_target.local_defaults ~image_tag:sha in
  let push_registry = "localhost:5000" in
  let env = Sol_cli_env_target.to_env_config ~name:workspace env_target in
  let plan = build_plan ~workspace ~services ~env in
  List.iter (dry_run_service ~workspace ~push_registry ~sha)
    plan.Sol_cli_deployment_plan.services

let run_apply ~workspace ~sha ~filter_path ~services ~repo_root ~confirm_group_change =
  check_contract ~filter_path;
  ensure_postgres_url ();
  print_header ~workspace ~sha ~dry_run:false;
  let env_target = Sol_cli_env_target.local_defaults ~image_tag:sha in
  let push_registry = "localhost:5000" in
  let env = Sol_cli_env_target.to_env_config ~name:workspace env_target in
  let plan = build_plan ~workspace ~services ~env in
  check_consumer_group_changes ~workspace ~confirm_group_change plan;
  let ctx_dir = repo_root ^ ".docker-ctx" in
  let pf_failed = ref false in
  prepare_context ~repo_root ~ctx_dir;
  (try
    List.iter (apply_service ~workspace ~ctx_dir ~push_registry ~sha ~pf_failed)
      plan.Sol_cli_deployment_plan.services
  with Deploy_failed msg ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
    Printf.eprintf "\nerror: %s\n" msg;
    exit 1);
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
  Printf.printf "Done. %d service(s) deployed.\n" (List.length services);
  Printf.printf "Run 'sol status' to check pod health.\n";
  let n = Sol_cli_workspace.pending_migration_count ~dir:(Sys.getcwd ()) in
  if n > 0 then
    Printf.printf
      "\nNote: %d migration file(s) found in db/migrations/ — run 'sol migrate' to apply.\n"
      n;
  Sol_cli_deployment_state.record_outcome workspace
    (Sol_cli_deployment_state.Applied {
      namespace = "default";
      name = workspace;
      image = sha;
      consumer_groups = List.map Sol_cli_plan_ids.Consumer_group.to_string
                          plan.Sol_cli_deployment_plan.consumer_groups;
    });
  if !pf_failed then exit 1

let run (req : Sol_cli_command_request.up_request) =
  let workspace = workspace_name () in
  let sha       = req.image_tag in
  let services  = discover_services ~filter_path:req.filter_path in

  if services = [] then begin
    Printf.eprintf "No services found in app/ with a Dockerfile.\n";
    exit 1
  end;

  match req.mode with
  | Sol_cli_command_request.Dry_run -> run_dry_run ~workspace ~sha ~services
  | Apply ->
    let repo_root = find_repo_root () in
    run_apply ~workspace ~sha ~filter_path:req.filter_path ~services ~repo_root
      ~confirm_group_change:req.confirm_group_change

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let path_arg =
  Arg.(value & pos 0 (some string) None &
       info [] ~docv:"PATH"
         ~doc:"Service path to build and deploy (default: all services in workspace). \
               'sol up' is local-only and has no target concept, so unlike \
               'sol deploy TARGET [path]' this positional is the optional \
               service-path filter, not a required deployment target.")

let dry_run_flag =
  Arg.(value & flag &
       info ["dry-run"]
         ~doc:"Print synthesized YAML to stdout without applying to the cluster")

let tag_arg =
  Arg.(value & opt (some string) None &
       info ["tag"] ~docv:"TAG"
         ~doc:"Docker image tag (default: short git SHA)")

let confirm_group_change_flag =
  Arg.(value & flag &
       info ["confirm-group-change"]
         ~doc:"Acknowledge that consumer group IDs have changed and proceed with deploy")

let cmd =
  Cmd.v
    (Cmd.info "up"
       ~doc:"Build images, synthesize k8s manifests, and deploy to the local \
             cluster. Local-only — no target concept, unlike 'sol deploy'.")
    Term.(const (fun filter_path dry_run tag confirm_group_change ->
        match Sol_cli_command_request.make_up_request
                ~filter_path ~dry_run ~tag ~confirm_group_change ~git_sha
          with
          | Ok req -> run req
          | Error msg ->
            Printf.eprintf "error: %s\n" msg;
            exit 1)
      $ path_arg $ dry_run_flag $ tag_arg $ confirm_group_change_flag)
