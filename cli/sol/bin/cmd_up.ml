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

let current_kube_context () =
  match Sol_cli_kubectl.config_current_context () with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> r.Sol_cli_process.stdout
  | _ -> ""
;;

let is_known_local_dev_context () = current_kube_context () = "k3d-sol-local"

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

let build_plan ~workspace ~sha ~services =
  match Sol_cli_up_execution.local_plan ~workspace ~sha services with
  | Ok plan -> plan
  | Error err ->
    Printf.eprintf "error: %s\n" (Sol_cli_deployment_plan.plan_error_to_string err);
    exit 1
;;

let check_contract ~filter_path =
  let findings = Sol_cli_check.run ~filter_path () in
  List.iter (fun f -> Printf.eprintf "%s\n" (Sol_cli_check.finding_to_string f)) findings;
  if Sol_cli_check.has_errors findings then exit 1
;;

let ensure_postgres_url () =
  if is_known_local_dev_context ()
  then (
    match Sys.getenv_opt "POSTGRES_URL" with
    | None | Some "" ->
      Unix.putenv
        "POSTGRES_URL"
        "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev"
    | Some _ -> ())
  else (
    match Sys.getenv_opt "POSTGRES_URL" with
    | None | Some "" ->
      Printf.eprintf
        "error: POSTGRES_URL is not set.\n\
         Set it in your environment before running 'sol up':\n\
        \  export POSTGRES_URL=postgresql://user:pass@host:5432/dbname\n";
      exit 1
    | Some _ -> ())
;;

let check_consumer_group_changes ~workspace ~confirm_group_change plan =
  let prev_groups = Sol_cli_deployment_state.load_deployed_groups workspace in
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
  | Ok ctx_dir -> ctx_dir
  | Error msg ->
    Printf.eprintf "error: %s\n" msg;
    exit 1
;;

let to_manifest_primitive = Sol_cli_up_execution.manifest_primitive

let print_service_start spec =
  Printf.printf
    "[%s] %s/%s\n%!"
    (primitive_label (to_manifest_primitive spec.Sol_cli_deployment_plan.primitive))
    spec.domain
    spec.source_name
;;

let dry_run_service ~workspace ~sha (spec : Sol_cli_deployment_plan.service_spec) =
  print_service_start spec;
  match
    Sol_cli_up_execution.apply_service_manifest
      ~workspace
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
  (match Sol_cli_up_execution.apply_service_manifest ~workspace ~dry_run:false spec with
   | Ok _ -> ()
   | Error msg -> raise (Deploy_failed msg));
  (match spec.primitive with
   | Sol_cli_deployment_plan.Fn -> ()
   | Sol_cli_deployment_plan.Svc | Sol_cli_deployment_plan.Worker ->
     Printf.printf "  waiting for rollout...\n%!";
     (match Sol_cli_up_execution.wait_for_service_rollout spec exec with
      | Ok () -> ()
      | Error msg -> raise (Deploy_failed msg)));
  match spec.primitive with
  | Sol_cli_deployment_plan.Svc ->
    let local_port = 8080 in
    if not (Sol_cli_port_forward.is_running exec.k8s_name)
    then (
      if
        Sol_cli_port_forward.detect_stale
          ~local_port
          ~namespace:exec.namespace
          ~target:("svc/" ^ exec.k8s_name)
      then Unix.sleepf 0.4;
      Sol_cli_port_forward.start
        { name = exec.k8s_name
        ; namespace = exec.namespace
        ; target = "svc/" ^ exec.k8s_name
        ; local_port
        ; remote_port = 80
        });
    let pf_alive = Sol_cli_port_forward.check_alive ~name:exec.k8s_name ~local_port in
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

let run_dry_run ~workspace ~sha ~services =
  print_header ~workspace ~sha ~dry_run:true;
  let plan = build_plan ~workspace ~sha ~services in
  List.iter (dry_run_service ~workspace ~sha) plan.Sol_cli_deployment_plan.services
;;

let run_apply ~workspace ~sha ~filter_path ~services ~repo_root ~confirm_group_change =
  check_contract ~filter_path;
  ensure_postgres_url ();
  print_header ~workspace ~sha ~dry_run:false;
  let plan = build_plan ~workspace ~sha ~services in
  check_consumer_group_changes ~workspace ~confirm_group_change plan;
  let pf_failed = ref false in
  let ctx_dir = prepare_context ~repo_root in
  (try
     List.iter
       (apply_service ~workspace ~ctx_dir ~sha ~pf_failed)
       plan.Sol_cli_deployment_plan.services
   with
   | Deploy_failed msg ->
     Sol_cli_up_execution.remove_build_context ~ctx_dir;
     Printf.eprintf "\nerror: %s\n" msg;
     exit 1);
  Sol_cli_up_execution.remove_build_context ~ctx_dir;
  let summary = Sol_cli_up_execution.post_deploy_summary ~cwd:(Sys.getcwd ()) plan in
  Printf.printf "Done. %d service(s) deployed.\n" summary.deployed_count;
  Printf.printf "Run 'sol status' to check pod health.\n";
  if summary.pending_migrations > 0
  then
    Printf.printf
      "\n\
       Note: %d migration file(s) found in db/migrations/ — run 'sol migrate' to apply.\n"
      summary.pending_migrations;
  Sol_cli_up_execution.record_applied ~workspace ~sha plan;
  if !pf_failed then exit 1
;;

let run (req : Sol_cli_command_request.up_request) =
  let workspace = workspace_name () in
  let sha = req.image_tag in
  let services = discover_services ~filter_path:req.filter_path in
  if services = []
  then (
    Printf.eprintf "No services found in app/ with a Dockerfile.\n";
    exit 1);
  match req.mode with
  | Sol_cli_command_request.Dry_run -> run_dry_run ~workspace ~sha ~services
  | Apply ->
    let repo_root = find_repo_root () in
    run_apply
      ~workspace
      ~sha
      ~filter_path:req.filter_path
      ~services
      ~repo_root
      ~confirm_group_change:req.confirm_group_change
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let path_arg =
  Arg.(
    value
    & pos 0 (some string) None
    & info
        []
        ~docv:"PATH"
        ~doc:
          "Service path to build and deploy (default: all services in workspace). 'sol \
           up' is local-only and has no target concept, so unlike 'sol deploy TARGET \
           [path]' this positional is the optional service-path filter, not a required \
           deployment target.")
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
      const (fun filter_path dry_run tag confirm_group_change ->
        match
          Sol_cli_command_request.make_up_request
            ~filter_path
            ~dry_run
            ~tag
            ~confirm_group_change
            ~git_sha
        with
        | Ok req -> run req
        | Error msg ->
          Printf.eprintf "error: %s\n" msg;
          exit 1)
      $ path_arg
      $ dry_run_flag
      $ tag_arg
      $ confirm_group_change_flag)
;;
