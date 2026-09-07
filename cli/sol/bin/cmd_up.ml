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

let run (req : Sol_cli_command_request.up_request) =
  let workspace = workspace_name () in
  let sha       = req.image_tag in
  let services  = discover_services ~filter_path:req.filter_path in
  let repo_root = find_repo_root () in
  let pf_failed = ref false in

  if services = [] then begin
    Printf.eprintf "No services found in app/ with a Dockerfile.\n";
    exit 1
  end;

  (* POSTGRES_URL must be set for non-local clusters; for local k3d it's
     auto-populated with the in-cluster dev URL unless already set. Dry-run
     is exempt since it only prints YAML. *)
  if not req.dry_run then begin
    if is_known_local_dev_context () then begin
      (match Sys.getenv_opt "POSTGRES_URL" with
       | None | Some "" ->
         Unix.putenv "POSTGRES_URL"
           "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev"
       | Some _ -> ())
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
  end;

  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  if req.dry_run then Printf.printf "(dry-run)\n";
  Printf.printf "\n%!";

  (* k3d maps sol-registry:5000 to the registry container; the env target owns
     that in-cluster address, while push uses localhost:5000 (host-accessible,
     build-step-only, not embedded in the plan). *)
  let env_target    = Sol_cli_env_target.local_defaults ~image_tag:sha in
  let push_registry = "localhost:5000" in

  let env  = Sol_cli_env_target.to_env_config ~name:workspace env_target in
  let plan =
    match Sol_cli_deployment_plan.of_services_result ~workspace ~env services with
    | Ok plan -> plan
    | Error err ->
      Printf.eprintf "error: %s\n" (Sol_cli_deployment_plan.plan_error_to_string err);
      exit 1
  in

  (* Consumer group rename/removal guard.  Skipped in dry-run — no state is
     loaded or written, and no blocking question is asked. *)
  if not req.dry_run then begin
    let prev_groups = Sol_cli_deployment_state.load_deployed_groups workspace in
    let next_groups = List.map Sol_cli_plan_ids.Consumer_group.to_string
                        plan.Sol_cli_deployment_plan.consumer_groups in
    let removed = Sol_cli_deployment_state.removed_consumer_groups ~prev:prev_groups ~next:next_groups in
    if removed <> [] && not req.confirm_group_change then begin
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
  end;

  (* vendor/ symlinks point outside the workspace, so docker build needs a
     resolved copy; rsync --copy-links builds one, excluding _build/.git to
     dodge stale dune internal symlinks. *)
  let ctx_dir = repo_root ^ ".docker-ctx" in
  if not req.dry_run then begin
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
    Printf.printf "Preparing build context...\n%!";
    let rsync_cmd = Printf.sprintf
      "rsync -a --copy-links --exclude='_build' --exclude='.git' %s/ %s"
      (Filename.quote repo_root) (Filename.quote ctx_dir) in
    if Sys.command rsync_cmd <> 0 then begin
      Printf.eprintf "error: failed to copy workspace for docker build context\n";
      exit 1
    end
  end;

  (try
    List.iter (fun (spec : Sol_cli_deployment_plan.service_spec) ->
      let k8s_name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
      let namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace in
      (* push_image is the host-accessible URL used for docker build/push and
         shown in dry-run output — it matches what actually gets written into the
         registry.  spec.image is the in-cluster URL baked into the manifest. *)
      let push_image = Sol_cli_deployment_plan.image_ref
        ~registry:push_registry ~workspace
        ~k8s_name:spec.k8s_name ~tag:sha in
      let repo_dir   = spec.source_dir in
      (* In dry-run the ctx_dir is not created; fall back to repo_root for the
         Dockerfile path so the plan output shows a real path. *)
      let build_ctx  = if req.dry_run then repo_root else ctx_dir in
      let dockerfile = Printf.sprintf "%s/%s/Dockerfile" build_ctx repo_dir in
      (* Sol_cli_deployment_plan.primitive -> Sol_cli_manifest.primitive;
         needed by both primitive_label below and pod_expectation_of_primitive
         further down, so compute it once per service instead of twice. *)
      let to_manifest_primitive = function
        | Sol_cli_deployment_plan.Svc    -> Svc
        | Sol_cli_deployment_plan.Worker -> Worker
        | Sol_cli_deployment_plan.Fn     -> Fn
      in

      Printf.printf "[%s] %s/%s\n%!"
        (primitive_label (to_manifest_primitive spec.primitive))
        spec.domain spec.source_name;

      if not req.dry_run then begin
        Printf.printf "  packaging %s...\n%!" push_image;
        (* Docker build/push failures dump their raw captured stderr
           verbatim (can be a full build log) -- deliberately unlike the
           rollout-wait site below, which has a purpose-built curated
           diagnosis available instead. No equivalent curation exists for
           a build/push failure, so raw output is the right call here. *)
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
         | Ok () -> ())
      end;

      (* dry-run shows push_image (what actually gets pushed); live apply uses
         spec.image (the cluster-resolved reference). *)
      let exec_spec =
        if req.dry_run then { spec with Sol_cli_deployment_plan.image = push_image }
        else spec
      in
      ignore (Sol_cli_executor.local ~workspace ~dry_run:req.dry_run exec_spec);

      if not req.dry_run then begin
        (match spec.primitive with
         | Sol_cli_deployment_plan.Svc
         | Sol_cli_deployment_plan.Worker ->
           Printf.printf "  waiting for rollout...\n%!";
           if wait_for_rollout ~namespace ~name:k8s_name <> 0 then begin
             (* FRIC-006: "rollout failed" alone doesn't say whether it's
                CrashLoopBackOff, ImagePullBackOff, a failing readiness
                probe, etc. Reuse the exact pod/event diagnosis 'sol
                status' already shows (Sol_cli_rollout_diagnosis) instead
                of leaving the user to run kubectl by hand to find out. *)
             let pod_expectation =
               Sol_cli_status.pod_expectation_of_primitive (to_manifest_primitive spec.primitive)
             in
             let diagnosis =
               Sol_cli_rollout_diagnosis.diagnose_service_live
                 ~pod_expectation ~ns:namespace ~service_name:spec.source_name
                 ~k8s_name ()
             in
             (* diagnose_service_live's Some case already renders its own
                "<service> rollout failed" headline (format_service_diagnosis/
                format_cronjob_diagnosis/etc, see sol_cli_rollout_diagnosis.ml)
                -- the same string sol status prints bare. Prepending another
                "rollout failed: ns/name" headline on top doubled it. Only
                fall back to our own bare headline when there's no diagnosis
                to show at all. *)
             raise (Deploy_failed (match diagnosis with
               | Some d -> d
               | None   -> Printf.sprintf "rollout failed: %s/%s" namespace k8s_name))
           end
         | Sol_cli_deployment_plan.Fn -> ());
        (match spec.primitive with
         | Sol_cli_deployment_plan.Svc ->
           let local_port = 8080 in
           if not (Sol_cli_port_forward.is_running k8s_name) then begin
             (* Before binding the port, check whether a stale Sol-managed
                port-forward from a different workspace/namespace already owns
                it.  Give the old process ~400 ms to release the port. *)
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
      end

    ) plan.Sol_cli_deployment_plan.services
  with Deploy_failed msg ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
    Printf.eprintf "\nerror: %s\n" msg;
    exit 1);

  if not req.dry_run then begin
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
    Printf.printf "Done. %d service(s) deployed.\n" (List.length services);
    Printf.printf "Run 'sol status' to check pod health.\n";
    let n = Sol_cli_workspace.pending_migration_count ~dir:(Sys.getcwd ()) in
    if n > 0 then
      Printf.printf
        "\nNote: %d migration file(s) found in db/migrations/ — run 'sol migrate' to apply.\n"
        n;
    (* Persist deployed consumer groups for future change detection. *)
    Sol_cli_deployment_state.record_outcome workspace
      (Sol_cli_deployment_state.Applied {
        namespace = "default";
        name = workspace;
        image = sha;
        consumer_groups = List.map Sol_cli_plan_ids.Consumer_group.to_string
                            plan.Sol_cli_deployment_plan.consumer_groups;
      });
    if !pf_failed then exit 1
  end

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
