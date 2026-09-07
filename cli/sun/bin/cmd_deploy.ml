(* sun deploy — CI/CD integration.
   Like sun up but skips the build step: images are already in a registry.
   Designed to run in CI after the build pipeline has pushed images. *)

open Cmdliner
open Sun_cli_manifest

let workspace_name () = Filename.basename (Sys.getcwd ())

let git_sha () =
  match Sun_cli_process.run (Sun_cli_process.cmd ["git"; "rev-parse"; "--short"; "HEAD"]) with
  | Ok r when r.Sun_cli_process.exit_code = 0 && r.Sun_cli_process.stdout <> "" ->
    r.Sun_cli_process.stdout
  | _ -> "dev"

let run (req : Sun_cli_command_request.deploy_request) =
  let workspace = workspace_name () in
  let sha       = req.image_tag in
  let services  = discover_services ~filter_path:req.filter_path in

  let resolved_config, target_cfg =
    match Sun_cli_config.load_for_target ~target:req.target with
    | Error e ->
      Printf.eprintf "error: %s\n" (Sun_cli_config.error_to_string e);
      exit 1
    | Ok cfg ->
      match Sun_cli_config.target cfg with
      | None ->
        Printf.eprintf "error: target %S not found\n" req.target;
        exit 1
      | Some target -> cfg, target
  in
  (* sun deploy always mutates a real cluster, so unlike sun plan
     (genuinely read-only, Sun_cli_config.load_for_target's own
     permissive-overlay contract is fine for it) it needs the stronger
     guarantee that this target was deliberately declared, not just
     shaped like <env>/<provider>/<region>. A typo'd region
     (prod/aws/us-east-2 when only .../us-east-1.yml exists) would
     otherwise silently inherit sun.yml's shared defaults and apply
     anyway. sun cloud apply/destroy carry the same check for their own
     mutating action, in cmd_cloud_tf.ml's config_vars ~strict. *)
  if not (Sys.file_exists (Sun_cli_config.target_file target_cfg)) then begin
    Printf.eprintf "error: no %s for target %S -- sun deploy requires an \
                     explicit target file, even an empty one, so a typo'd \
                     or unintended target can't silently inherit sun.yml's \
                     shared defaults and deploy anyway.\n"
      (Sun_cli_config.target_file target_cfg) req.target;
    exit 1
  end;
  (* No hardcoded local-registry fallback here, deliberately: sun deploy is
     always a customer-cluster path (it never constructs
     Sun_cli_env_target.Local, unlike sun up) -- an unresolvable registry
     must reach customer_cloud_defaults's empty-registry check below and
     fail loudly, not silently point a real deploy at a k3d-only address. *)
  let registry =
    match req.registry with
    | Some r -> r
    | None ->
      (match target_cfg.Sun_cli_config.registry with
       | Some r -> r
       | None   -> "")
  in

  if services = [] then begin
    Printf.eprintf "No services found in app/ with a Dockerfile.\n";
    exit 1
  end;

  (* Pre-flight: POSTGRES_URL must be set when deploying live credentials to a
     cluster.  Skip the check for --dry-run and --emit-to: those modes either
     only print YAML or emit redacted GitOps manifests with no real values. *)
  if not req.dry_run && req.emit_to = None then begin
    match Sys.getenv_opt "POSTGRES_URL" with
    | None | Some "" ->
      Printf.eprintf
        "error: POSTGRES_URL is not set.\n\
         Set it in your environment before running 'sun deploy':\n\
         \  export POSTGRES_URL=postgresql://user:pass@host:5432/dbname\n";
      exit 1
    | Some _ -> ()
  end;

  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  (match req.emit_to with
   | Some dir -> Printf.printf "emit-to: %s\n" dir
   | None when req.dry_run -> Printf.printf "(dry-run)\n"
   | None -> ());
  Printf.printf "\n%!";

  let env_target =
    match Sun_cli_env_target.customer_cloud_defaults
            ~registry
            ~image_tag:sha
            ~emit_to:req.emit_to
            ()
    with
    | Ok t      -> t
    | Error msg ->
      Printf.eprintf "error: %s\n" msg;
      exit 1
  in
  (* Guard: Kubernetes_live is never allowed with a GitOps target.
     Combining the two would write plaintext secret values into the GitOps
     repository, leaking them to everyone with read access to the repo. *)
  (match env_target, req.secret_backend with
   | Sun_cli_env_target.Customer_gitops _, Sun_cli_manifest.Kubernetes_live ->
     Printf.eprintf
       "error: cannot use --secret-backend kubernetes-live with --emit-to \
        (GitOps mode).\n\
        \  This combination would write plaintext secrets into the GitOps \
        repository,\n\
        \  leaking them to every reader of the repo.\n\
        \  Use --secret-backend kubernetes-placeholder (the default) or \
        --secret-backend external-secrets instead.\n";
     exit 1
   | _ -> ());

  let env  = { (Sun_cli_env_target.to_env_config ~name:workspace env_target) with
               Sun_cli_deployment_plan.secret_backend = req.secret_backend;
               env = Some target_cfg.Sun_cli_config.env } in
  let plan =
    match Sun_cli_deployment_plan.of_services_result ~workspace ~env ~resolved_config services with
    | Ok plan -> plan
    | Error err ->
      Printf.eprintf "error: %s\n" (Sun_cli_deployment_plan.plan_error_to_string err);
      exit 1
  in

  (* Consumer group rename/removal guard (skipped in GitOps/emit-to mode,
     since that path does not touch the cluster directly). *)
  if not req.dry_run && req.emit_to = None then begin
    let prev_groups = Sun_cli_deployment_state.load_deployed_groups workspace in
    let next_groups = List.map Sun_cli_plan_ids.Consumer_group.to_string
                        plan.Sun_cli_deployment_plan.consumer_groups in
    let removed = Sun_cli_deployment_state.removed_consumer_groups ~prev:prev_groups ~next:next_groups in
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

  (match req.emit_plan_to with
   | None -> ()
   | Some path ->
     let json_str = Yojson.Safe.pretty_to_string (Sun_cli_deployment_plan.to_json plan) in
     if path = "-" then begin
       print_string json_str;
       print_char '\n'
     end else begin
       let oc = open_out path in
       output_string oc json_str;
       output_char oc '\n';
       close_out oc;
       Printf.printf "Plan written to %s\n%!" path
     end);

  let mode =
    if req.dry_run then Sun_cli_executor.Dry_run
    else match req.emit_to with
      | Some dir -> Sun_cli_executor.Emit_to dir
      | None     -> Sun_cli_executor.Apply
  in

  List.iter (fun (spec : Sun_cli_deployment_plan.service_spec) ->
    Printf.printf "[%s] %s/%s\n%!" (primitive_label
      (match spec.primitive with
       | Sun_cli_deployment_plan.Svc    -> Svc
       | Sun_cli_deployment_plan.Worker -> Worker
       | Sun_cli_deployment_plan.Fn     -> Fn))
    spec.domain spec.source_name)
  plan.Sun_cli_deployment_plan.services;

  (try
    let results =
      match Sun_cli_executor.run_plan ~workspace ~env:target_cfg.Sun_cli_config.env
              ~mode ~secret_backend:req.secret_backend
              plan.Sun_cli_deployment_plan.services with
      | Ok rs -> rs
      | Error msg ->
        Printf.eprintf "\nerror: %s\n" msg;
        exit 1
    in
    List.iter (fun (r : Sun_cli_executor.result) ->
      match mode with
      | Sun_cli_executor.Emit_to dir ->
        let path = Filename.concat dir
          (Printf.sprintf "%s-%s.yaml" r.Sun_cli_executor.namespace r.Sun_cli_executor.name) in
        Printf.printf "  ✓  %s\n%!" path
      | Sun_cli_executor.Apply ->
        Printf.printf "  ✓  namespace %s  image %s\n\n%!" r.Sun_cli_executor.namespace r.Sun_cli_executor.image
      | Sun_cli_executor.Dry_run -> ())
    results
  with Deploy_failed msg ->
    Printf.eprintf "\nerror: %s\n" msg;
    exit 1);

  (match req.emit_to with
   | Some dir ->
     Printf.printf "\nManifests written to %s/\n" dir;
     Printf.printf "Commit and push to your GitOps repo, then Argo CD will apply them.\n"
   | None when not req.dry_run ->
     Printf.printf "\nDone. %d service(s) deployed.\n" (List.length services);
     Printf.printf "Run 'sun status' to check pod health.\n";
     Sun_cli_deployment_state.record_outcome workspace
       (Sun_cli_deployment_state.Applied {
         namespace = "default";
         name = workspace;
         image = sha;
         consumer_groups = List.map Sun_cli_plan_ids.Consumer_group.to_string
                             plan.Sun_cli_deployment_plan.consumer_groups;
       });
     (* OBS-037: one structured Loki log line per deployed service, for
        OBS-038's deploy/release timeline dashboard. Real apply only (this
        branch is neither --dry-run nor --emit-to already); a push failure
        must never fail a deploy that has already succeeded, so this is
        wrapped on top of cmd_deploy_event.ml's own per-event try/with as a
        second safety net -- cancellation/fatal exceptions still propagate,
        matching Obs_eio's own exclusion list. *)
     let backend =
       match target_cfg.Sun_cli_config.observability_backend with
       | Some s ->
         (match Sun_cli_observability_url.backend_of_string s with
          | Some b -> b
          | None -> Sun_cli_observability_url.Local)
       | None -> Sun_cli_observability_url.Local
     in
     let deploy_events =
       List.map (fun (spec : Sun_cli_deployment_plan.service_spec) ->
         { Sun_cli_deploy_event.workspace;
           env       = target_cfg.Sun_cli_config.env;
           domain    = spec.domain;
           service   = Sun_cli_kubernetes_name.k8s_name_to_string spec.k8s_name;
           primitive = primitive_label
             (match spec.primitive with
              | Sun_cli_deployment_plan.Svc    -> Svc
              | Sun_cli_deployment_plan.Worker -> Worker
              | Sun_cli_deployment_plan.Fn     -> Fn);
           release   = Sun_cli_manifest_yaml.release_of_image spec.image;
         }
       ) plan.Sun_cli_deployment_plan.services
     in
     (try Cmd_deploy_event.push_all ~backend ~explicit_url:req.loki_push_url deploy_events
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
      | exn ->
        Printf.eprintf "warning: deploy-event log push failed: %s\n%!" (Printexc.to_string exn))
   | None -> ())

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let target_arg =
  Arg.(required & pos 0 (some string) None &
       info [] ~docv:"TARGET"
         ~doc:"Deployment target path: <env>/<provider>/<region>, e.g. \
               dev/aws/us-east-1 — same convention as 'sun plan'. Resolves \
               sun.yml + sun/<env>/<provider>/<region>.yml for registry/env \
               defaults. Unlike 'sun up' (local-only, no target concept), \
               this is required.")

let path_arg =
  Arg.(value & pos 1 (some string) None &
       info [] ~docv:"PATH"
         ~doc:"Service path to deploy (default: all services in workspace)")

let dry_run_flag =
  Arg.(value & flag &
       info ["dry-run"]
         ~doc:"Print synthesized YAML to stdout without applying")

let emit_to_arg =
  Arg.(value & opt (some string) None &
       info ["emit-to"] ~docv:"DIR"
         ~doc:"Write YAML files to DIR instead of applying (GitOps mode). \
               One file per service: <namespace>-<name>.yaml")

let emit_plan_to_arg =
  Arg.(value & opt (some string) None &
       info ["emit-plan-to"] ~docv:"FILE"
         ~doc:"Write the deployment plan as JSON to FILE before executing. \
               Use '-' to print to stdout. Plan format is experimental.")

let image_tag_arg =
  Arg.(value & opt (some string) None &
       info ["image-tag"] ~docv:"TAG"
         ~doc:"Image tag to deploy (default: short git SHA). \
               In CI, pass the exact SHA built by the preceding job.")

let registry_arg =
  Arg.(value & opt (some string) None &
       info ["registry"] ~docv:"URL"
         ~doc:"Container registry prefix, e.g. \
               123456789.dkr.ecr.us-east-1.amazonaws.com. \
               Omit to fall back to the resolved target's own registry \
               (sun/<env>/<provider>/<region>.yml); required if neither is set.")

let secret_backend_arg =
  Arg.(value & opt string "kubernetes-placeholder" &
       info ["secret-backend"] ~docv:"BACKEND"
         ~doc:"Secret backend for GitOps output. \
               'kubernetes-placeholder' (default) emits a redacted Kubernetes Secret; \
               'external-secrets' emits an ExternalSecret CRD for the External Secrets Operator. \
               Only meaningful with --emit-to.")

let secret_store_ref_arg =
  Arg.(value & opt (some string) None &
       info ["secret-store-ref"] ~docv:"NAME"
         ~doc:"Name of the SecretStore or ClusterSecretStore to reference. \
               Required when --secret-backend=external-secrets.")

let secret_store_kind_arg =
  Arg.(value & opt (some string) None &
       info ["secret-store-kind"] ~docv:"KIND"
         ~doc:"Kind of the secret store reference (default: ClusterSecretStore). \
               Use 'SecretStore' for a namespace-scoped store.")

let key_prefix_arg =
  Arg.(value & opt (some string) None &
       info ["key-prefix"] ~docv:"PREFIX"
         ~doc:"Prefix to prepend to each secret key when looking up in the external store \
               (default: \"\"). Example: 'myworkspace/' produces keys like 'myworkspace/POSTGRES_URL'.")

let refresh_interval_arg =
  Arg.(value & opt (some string) None &
       info ["refresh-interval"] ~docv:"INTERVAL"
         ~doc:"How often ESO should sync the secret from the external store (default: 1h). \
               Examples: '1h', '30m', '5m'.")

let secret_backend_term =
  let build str store_ref store_kind key_prefix refresh_interval emit_to =
    match str with
    | "kubernetes-placeholder" | "" -> `Ok Sun_cli_manifest.Kubernetes_placeholder
    | "external-secrets" when emit_to = None ->
      Printf.eprintf "warning: --secret-backend external-secrets is only meaningful \
                      with --emit-to; using kubernetes-placeholder.\n";
      `Ok Sun_cli_manifest.Kubernetes_placeholder
    | "external-secrets" ->
      (match store_ref with
       | None ->
         `Error (true, "--secret-store-ref is required when --secret-backend=external-secrets")
       | Some sref ->
         `Ok (Sun_cli_manifest.External_secrets {
           store_ref        = sref;
           store_kind       = Option.value store_kind ~default:"ClusterSecretStore";
           key_prefix       = Option.value key_prefix ~default:"";
           refresh_interval = Option.value refresh_interval ~default:"1h";
         }))
    | other ->
      `Error (true, Printf.sprintf "unknown --secret-backend value %S \
                    (expected: kubernetes-placeholder | external-secrets)" other)
  in
  Term.(ret (const build
             $ secret_backend_arg $ secret_store_ref_arg $ secret_store_kind_arg
             $ key_prefix_arg $ refresh_interval_arg $ emit_to_arg))

let confirm_group_change_flag =
  Arg.(value & flag &
       info ["confirm-group-change"]
         ~doc:"Acknowledge that consumer group IDs have changed and proceed with deploy")

let loki_push_url_arg =
  Arg.(value & opt (some string) None &
       info ["loki-push-url"] ~docv:"URL"
         ~doc:"Loki push URL for this deploy's release-event log line \
               (OBS-037), e.g. https://logs-prod-000.grafana.net. When \
               omitted: for the 'local'/'self_hosted_durable' \
               observability backends, sun deploy probes the cluster for \
               an in-cluster Loki (svc/loki -n monitoring) and, if found, \
               port-forwards to it for the duration of the push; for \
               'external' there is no in-cluster Loki and no configured \
               push URL, so pass this flag to record the event at all. A \
               push failure never fails the deploy.")

let cmd =
  Cmd.v
    (Cmd.info "deploy"
       ~doc:"Deploy pre-built images to a cluster (CI/CD integration). \
             Like 'sun up' but skips the build step — images must already \
             be in the registry. Takes a required TARGET positional \
             (<env>/<provider>/<region>, e.g. dev/aws/us-east-1), unlike \
             'sun up' whose positional is the optional service-path filter — \
             'sun up' is local-only and has no target to resolve.")
    Term.(const (fun target filter_path dry_run emit_to emit_plan_to image_tag registry
                     secret_backend confirm_group_change loki_push_url ->
        match Sun_cli_command_request.make_deploy_request
                ~target ~filter_path ~dry_run ~emit_to ~emit_plan_to
                ~image_tag ~registry ~secret_backend ~confirm_group_change
                ~loki_push_url ~git_sha
          with
          | Ok req -> run req
          | Error msg ->
            Printf.eprintf "error: %s\n" msg;
            exit 1)
          $ target_arg $ path_arg $ dry_run_flag $ emit_to_arg
          $ emit_plan_to_arg $ image_tag_arg $ registry_arg
          $ secret_backend_term $ confirm_group_change_flag $ loki_push_url_arg)
