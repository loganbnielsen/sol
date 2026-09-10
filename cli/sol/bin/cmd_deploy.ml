(* sol deploy — CI/CD integration.
   Like sol up but skips the build step: images are already in a registry.
   Designed to run in CI after the build pipeline has pushed images. *)

open Cmdliner
open Sol_cli_manifest

let workspace_name () = Filename.basename (Sys.getcwd ())

let git_sha () =
  match
    Sol_cli_process.run (Sol_cli_process.cmd [ "git"; "rev-parse"; "--short"; "HEAD" ])
  with
  | Ok r when r.Sol_cli_process.exit_code = 0 && r.Sol_cli_process.stdout <> "" ->
    r.Sol_cli_process.stdout
  | _ -> "dev"
;;

(* EXP-029: after a real apply, print a port-forward hint for each HTTP
   service so the engineer doesn't need a separate 'sol status' call to
   discover the endpoint. Same ClusterIP+port-80 detection cmd_status.ml's
   print_raw_diagnostics already uses -- only Svc-primitive services ever
   get a Service resource (sol_cli_deployment_render.ml only emits
   service_doc for Http_service shapes), so this naturally excludes
   worker/fn services without needing to thread primitive info through. *)
let print_service_urls (results : Sol_cli_executor.result list) =
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
         Sol_cli_kubectl.get_raw
           ~args:[ "get"; "svc"; "-n"; ns; "-o"; "jsonpath=" ^ jsonpath ]
       with
       | Ok r when r.Sol_cli_process.exit_code = 0 && r.Sol_cli_process.stdout <> "" ->
         let port80_jsonpath = "{.spec.ports[?(@.port==80)].port}" in
         String.split_on_char ' ' r.Sol_cli_process.stdout
         |> List.filter (fun name -> List.mem name deployed_names)
         |> List.iter (fun name ->
           match
             Sol_cli_kubectl.get
               ~resource:"svc"
               ~name
               ~namespace:ns
               ~output:("jsonpath=" ^ port80_jsonpath)
           with
           | Ok gr
             when gr.Sol_cli_process.exit_code = 0 && gr.Sol_cli_process.stdout <> "" ->
             Printf.printf "  →  http://localhost:8080  (%s)\n%!" name
           | _ -> ())
       | _ -> ())
    namespaces
;;

let check_contract ~filter_path =
  let findings = Sol_cli_check.run ~filter_path () in
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

let check_apply_environment ~filter_path =
  check_contract ~filter_path;
  ensure_postgres_url ()
;;

type deploy_context =
  { workspace : string
  ; sha : string
  ; registry : string
  ; secret_backend : Sol_cli_manifest.secret_backend
  ; emit_plan_to : string option
  ; target_cfg : Sol_cli_config.target
  ; resolved_config : Sol_cli_config.t
  ; services : Sol_cli_manifest.service list
  }

let print_header ~workspace ~sha ?mode_line () =
  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  Option.iter (Printf.printf "%s\n") mode_line;
  Printf.printf "\n%!"
;;

let build_plan ctx ~emit_to =
  let env_target =
    match
      Sol_cli_env_target.customer_cloud_defaults
        ~registry:ctx.registry
        ~image_tag:ctx.sha
        ~emit_to
        ()
    with
    | Ok t -> t
    | Error msg ->
      Printf.eprintf "error: %s\n" msg;
      exit 1
  in
  (* Guard: Kubernetes_live is never allowed with a GitOps target.
     Combining the two would write plaintext secret values into the GitOps
     repository, leaking them to everyone with read access to the repo. *)
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
    { (Sol_cli_env_target.to_env_config ~name:ctx.workspace env_target) with
      Sol_cli_deployment_plan.secret_backend = ctx.secret_backend
    ; env = Some ctx.target_cfg.Sol_cli_config.env
    ; cluster_issuer =
        Option.value
          ctx.target_cfg.Sol_cli_config.cluster_issuer
          ~default:"letsencrypt-prod"
    }
  in
  match
    Sol_cli_factory.plan_of_services
      ~workspace:ctx.workspace
      ~env
      ~resolved_config:ctx.resolved_config
      ctx.services
  with
  | Ok plan -> plan
  | Error msg ->
    Printf.eprintf "error: %s\n" msg;
    exit 1
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

let run_plan_or_exit ~workspace ~target_env ~mode ~secret_backend plan =
  try
    match
      Sol_cli_factory.execute ~workspace ~env:target_env ~mode ~secret_backend plan
    with
    | Ok rs -> rs
    | Error msg ->
      Printf.eprintf "\nerror: %s\n" msg;
      exit 1
  with
  | Deploy_failed msg ->
    Printf.eprintf "\nerror: %s\n" msg;
    exit 1
;;

let run_dry_run ctx ~emit_to =
  print_header ~workspace:ctx.workspace ~sha:ctx.sha ~mode_line:"(dry-run)" ();
  let plan = build_plan ctx ~emit_to in
  write_plan_if_requested ~emit_plan_to:ctx.emit_plan_to plan;
  print_planned_services plan;
  ignore
    (run_plan_or_exit
       ~workspace:ctx.workspace
       ~target_env:ctx.target_cfg.Sol_cli_config.env
       ~mode:Sol_cli_executor.Dry_run
       ~secret_backend:ctx.secret_backend
       plan)
;;

let run_emit ctx ~dir =
  print_header
    ~workspace:ctx.workspace
    ~sha:ctx.sha
    ~mode_line:(Printf.sprintf "emit-to: %s" dir)
    ();
  let plan = build_plan ctx ~emit_to:(Some dir) in
  write_plan_if_requested ~emit_plan_to:ctx.emit_plan_to plan;
  print_planned_services plan;
  let results =
    run_plan_or_exit
      ~workspace:ctx.workspace
      ~target_env:ctx.target_cfg.Sol_cli_config.env
      ~mode:(Sol_cli_executor.Emit_to dir)
      ~secret_backend:ctx.secret_backend
      plan
  in
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

let push_deploy_events ~workspace ~target_cfg ~loki_push_url plan =
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
         ; release = Sol_cli_manifest_yaml.release_of_image spec.image
         })
      plan.Sol_cli_deployment_plan.services
  in
  try Cmd_deploy_event.push_all ~backend ~explicit_url:loki_push_url deploy_events with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
  | exn ->
    Printf.eprintf
      "warning: deploy-event log push failed: %s\n%!"
      (Printexc.to_string exn)
;;

let run_apply ctx ~filter_path ~confirm_group_change ~loki_push_url =
  check_apply_environment ~filter_path;
  print_header ~workspace:ctx.workspace ~sha:ctx.sha ();
  let target_env = ctx.target_cfg.Sol_cli_config.env in
  let plan = build_plan ctx ~emit_to:None in
  check_consumer_group_changes ~workspace:ctx.workspace ~confirm_group_change plan;
  write_plan_if_requested ~emit_plan_to:ctx.emit_plan_to plan;
  print_planned_services plan;
  let results =
    run_plan_or_exit
      ~workspace:ctx.workspace
      ~target_env
      ~mode:Sol_cli_executor.Apply
      ~secret_backend:ctx.secret_backend
      plan
  in
  List.iter
    (fun (r : Sol_cli_executor.result) ->
       Printf.printf
         "  ✓  namespace %s  image %s\n\n%!"
         r.Sol_cli_executor.namespace
         r.Sol_cli_executor.image)
    results;
  Printf.printf "\nDone. %d service(s) deployed.\n" (List.length ctx.services);
  print_service_urls results;
  Printf.printf "Run 'sol status' to check pod health.\n";
  Sol_cli_deployment_state.record_outcome
    ctx.workspace
    (Sol_cli_deployment_state.Applied
       { namespace = "default"
       ; name = ctx.workspace
       ; image = ctx.sha
       ; consumer_groups =
           List.map
             Sol_cli_plan_ids.Consumer_group.to_string
             plan.Sol_cli_deployment_plan.consumer_groups
       });
  push_deploy_events
    ~workspace:ctx.workspace
    ~target_cfg:ctx.target_cfg
    ~loki_push_url
    plan
;;

let run (req : Sol_cli_command_request.deploy_request) =
  let workspace = workspace_name () in
  let sha = req.image_tag in
  let services = discover_services ~filter_path:req.filter_path in
  let resolved_config, target_cfg =
    match Sol_cli_config.load_for_target ~target:req.target with
    | Error e ->
      Printf.eprintf "error: %s\n" (Sol_cli_config.error_to_string e);
      exit 1
    | Ok cfg ->
      (match Sol_cli_config.target cfg with
       | None ->
         Printf.eprintf "error: target %S not found\n" req.target;
         exit 1
       | Some target -> cfg, target)
  in
  (* sol deploy always mutates a real cluster, so unlike sol plan
     (genuinely read-only, Sol_cli_config.load_for_target's own
     permissive-overlay contract is fine for it) it needs the stronger
     guarantee that this target was deliberately declared, not just
     shaped like <env>/<provider>/<region>. A typo'd region
     (prod/aws/us-east-2 when only .../us-east-1.yml exists) would
     otherwise silently inherit sol.yml's shared defaults and apply
     anyway. sol cloud apply/destroy carry the same check for their own
     mutating action, in cmd_cloud_tf.ml's config_vars ~strict. *)
  if not (Sys.file_exists (Sol_cli_config.target_file target_cfg))
  then (
    Printf.eprintf
      "error: no %s for target %S -- sol deploy requires an explicit target file, even \
       an empty one, so a typo'd or unintended target can't silently inherit sol.yml's \
       shared defaults and deploy anyway.\n"
      (Sol_cli_config.target_file target_cfg)
      req.target;
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
  if services = []
  then (
    Printf.eprintf "No services found in app/ with a Dockerfile.\n";
    exit 1);
  let ctx =
    { workspace
    ; sha
    ; registry
    ; secret_backend = req.secret_backend
    ; emit_plan_to = req.emit_plan_to
    ; target_cfg
    ; resolved_config
    ; services
    }
  in
  match req.action with
  | Sol_cli_command_request.Deploy_dry_run { emit_to } -> run_dry_run ctx ~emit_to
  | Deploy_emit_to dir -> run_emit ctx ~dir
  | Deploy_apply ->
    run_apply
      ctx
      ~filter_path:req.filter_path
      ~confirm_group_change:req.confirm_group_change
      ~loki_push_url:req.loki_push_url
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
           same convention as 'sol plan'. Resolves sol.yml + \
           sol/<env>/<provider>/<region>.yml for registry/env defaults. Unlike 'sol up' \
           (local-only, no target concept), this is required.")
;;

let path_arg =
  Arg.(
    value
    & pos 1 (some string) None
    & info
        []
        ~docv:"PATH"
        ~doc:"Service path to deploy (default: all services in workspace)")
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

let registry_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "registry" ]
        ~docv:"URL"
        ~doc:
          "Container registry prefix, e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com. \
           Omit to fall back to the resolved target's own registry \
           (sol/<env>/<provider>/<region>.yml); required if neither is set.")
;;

let secret_backend_arg =
  Arg.(
    value
    & opt string "kubernetes-placeholder"
    & info
        [ "secret-backend" ]
        ~docv:"BACKEND"
        ~doc:
          "Secret backend for GitOps output. 'kubernetes-placeholder' (default) emits a \
           redacted Kubernetes Secret; 'external-secrets' emits an ExternalSecret CRD \
           for the External Secrets Operator. Only meaningful with --emit-to.")
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
    | "kubernetes-placeholder" | "" -> `Ok Sol_cli_manifest.Kubernetes_placeholder
    | "external-secrets" when emit_to = None ->
      Printf.eprintf
        "warning: --secret-backend external-secrets is only meaningful with --emit-to; \
         using kubernetes-placeholder.\n";
      `Ok Sol_cli_manifest.Kubernetes_placeholder
    | "external-secrets" ->
      (match store_ref with
       | None ->
         `Error
           (true, "--secret-store-ref is required when --secret-backend=external-secrets")
       | Some sref ->
         `Ok
           (Sol_cli_manifest.External_secrets
              { store_ref = sref
              ; store_kind = Option.value store_kind ~default:"ClusterSecretStore"
              ; key_prefix = Option.value key_prefix ~default:""
              ; refresh_interval = Option.value refresh_interval ~default:"1h"
              }))
    | other ->
      `Error
        ( true
        , Printf.sprintf
            "unknown --secret-backend value %S (expected: kubernetes-placeholder | \
             external-secrets)"
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
             filter_path
             dry_run
             emit_to
             emit_plan_to
             image_tag
             registry
             secret_backend
             confirm_group_change
             loki_push_url
           ->
           match
             Sol_cli_command_request.make_deploy_request
               ~target
               ~filter_path
               ~dry_run
               ~emit_to
               ~emit_plan_to
               ~image_tag
               ~registry
               ~secret_backend
               ~confirm_group_change
               ~loki_push_url
               ~git_sha
           with
           | Ok req -> run req
           | Error msg ->
             Printf.eprintf "error: %s\n" msg;
             exit 1)
      $ target_arg
      $ path_arg
      $ dry_run_flag
      $ emit_to_arg
      $ emit_plan_to_arg
      $ image_tag_arg
      $ registry_arg
      $ secret_backend_term
      $ confirm_group_change_flag
      $ loki_push_url_arg)
;;
