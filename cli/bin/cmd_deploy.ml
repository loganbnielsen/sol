open Cmdliner
open Sol_cli_manifest

let workspace_name = Sol_cli_workspace.current_name

open Result.Syntax

let print_service_urls names =
  names |> List.iter (Printf.printf "  →  http://localhost:8080  (%s)\n%!")
;;

let check_contract ~facts ~services =
  let findings = Sol_cli_check.run_services ~facts services in
  findings
  |> List.iter (fun f -> Printf.eprintf "%s\n" (Sol_cli_check.finding_to_string f));
  if Sol_cli_check.has_errors findings then Error (Sol_cli_exit.reported ()) else Ok ()
;;

let ensure_postgres_url () =
  match Sol_cli_string.env "POSTGRES_URL" with
  | None ->
    Error
      (Sol_cli_exit.error
         "POSTGRES_URL is not set.\n\
          Set it in your environment before running 'sol deploy':\n\
         \  export POSTGRES_URL=postgresql://user:pass@host:5432/dbname")
  | Some _ -> Ok ()
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
  | Ok () -> Ok ()
  | Error msg -> Error (Sol_cli_exit.failure msg)
;;

let check_apply_environment ~facts ~services =
  let* () = check_contract ~facts ~services in
  ensure_postgres_url ()
;;

let print_header ~workspace ~sha ?mode_line () =
  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  Option.iter (Printf.printf "%s\n") mode_line;
  Printf.printf "\n%!"
;;

let build_plan (ctx : Sol_cli_deploy_run.context) ~emit_to =
  let input : Sol_cli_deploy_selection.Planning_input.t =
    { workspace = ctx.execution.workspace
    ; registry = ctx.registry
    ; sha = ctx.sha
    ; emit_to
    ; secret_backend = ctx.secret_backend
    ; config = ctx.resolved_config
    ; facts = ctx.facts
    ; inventory = ctx.inventory
    ; requested_scope = ctx.requested_scope
    ; image_refs = ctx.image_refs
    ; services = ctx.services
    }
  in
  let* plan =
    Sol_cli_deploy_selection.plan input
    |> Result.map_error (function
      | Sol_cli_deploy_selection.Refused message -> Sol_cli_exit.error message
      | Preflight (profile, findings) ->
        Sol_cli_exit.failure (Sol_cli_profile_preflight.report profile findings))
  in
  plan.profile
  |> Option.iter (fun (claim : Sol_cli_deployment_plan.profile_claim) ->
    Printf.printf
      "Profile: %s (preflight passed)\n%!"
      (Sol_cli_profile.to_string claim.profile));
  Ok plan
;;

let write_plan_if_requested ~emit_plan_to plan =
  match emit_plan_to with
  | None -> Ok ()
  | Some path ->
    let json_str = Yojson.Safe.pretty_to_string (Sol_cli_deployment_plan.to_json plan) in
    if path = "-"
    then (
      print_string json_str;
      print_char '\n';
      Ok ())
    else
      Sol_cli_fs.write_atomic path (json_str ^ "\n")
      |> Result.map (fun () -> Printf.printf "Plan written to %s\n%!" path)
      |> Sol_cli_exit.of_msg
;;

let to_manifest_primitive = function
  | Sol_cli_deployment_plan.Svc -> Svc
  | Sol_cli_deployment_plan.Worker -> Worker
  | Sol_cli_deployment_plan.Fn -> Fn
;;

let print_planned_services plan =
  plan.Sol_cli_deployment_plan.services
  |> List.iter (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    Printf.printf
      "[%s] %s/%s\n%!"
      (primitive_label (to_manifest_primitive spec.primitive))
      spec.domain
      spec.source_name)
;;

let record_plan run_log plan =
  Sol_cli_run_log.append_phase_log
    run_log
    ~phase:"plan"
    (Format.asprintf "%a" Sol_cli_deployment_plan.pp_summary plan)
;;

let run_failed msg = Sol_cli_exit.failure ("\nerror: " ^ msg)

let run_plan ctx ~phase ~mode plan =
  Sol_cli_deploy_run.run_plan_result ctx ~phase ~mode plan |> Result.map_error run_failed
;;

let check_migration_prerequisite ~ctx ~plan ~live =
  Sol_cli_deploy_run.migration_prerequisite ctx ~plan ~live
  |> Result.map_error (function
    | Sol_cli_deploy_run.Refused message -> Sol_cli_exit.error message
    | Failed report -> Sol_cli_exit.failure report)
;;

let check_substrate_prerequisite ~ctx ~plan ~live =
  Sol_cli_deploy_run.substrate_prerequisite ctx ~plan ~live
  |> Result.map_error (function
    | Sol_cli_deploy_run.Refused message -> Sol_cli_exit.error message
    | Failed report -> Sol_cli_exit.failure report)
;;

let push_deploy_events ~ctx ~target_cfg ~loki_push_url events =
  let backend =
    Option.bind
      target_cfg.Sol_cli_config.observability_backend
      Sol_cli_observability_url.backend_of_string
    |> Option.value ~default:Sol_cli_observability_url.Local
  in
  try Cmd_deploy_event.push_all ~ctx ~backend ~explicit_url:loki_push_url events with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
  | exn ->
    Printf.eprintf
      "warning: deploy-event log push failed: %s\n%!"
      (Printexc.to_string exn)
;;

let run_dry_run (ctx : Sol_cli_deploy_run.context) ~emit_to =
  print_header ~workspace:ctx.execution.workspace ~sha:ctx.sha ~mode_line:"(dry-run)" ();
  let* plan = build_plan ctx ~emit_to in
  let* () = write_plan_if_requested ~emit_plan_to:ctx.emit_plan_to plan in
  print_planned_services plan;
  let* () = check_substrate_prerequisite ~ctx ~plan ~live:false in
  let* () = check_migration_prerequisite ~ctx ~plan ~live:false in
  record_plan ctx.run_log plan;
  let* _ = run_plan ctx ~phase:"dry-run" ~mode:Sol_cli_executor.Dry_run plan in
  Ok ()
;;

let run_emit (ctx : Sol_cli_deploy_run.context) ~dir =
  print_header
    ~workspace:ctx.execution.workspace
    ~sha:ctx.sha
    ~mode_line:(Printf.sprintf "emit-to: %s" dir)
    ();
  let* plan = build_plan ctx ~emit_to:(Some dir) in
  let* () = write_plan_if_requested ~emit_plan_to:ctx.emit_plan_to plan in
  print_planned_services plan;
  let* () = check_migration_prerequisite ~ctx ~plan ~live:false in
  record_plan ctx.run_log plan;
  let* results = run_plan ctx ~phase:"emit" ~mode:(Sol_cli_executor.Emit_to dir) plan in
  results
  |> List.iter (fun (r : Sol_cli_executor.result) ->
    let path = Filename.concat dir (Printf.sprintf "%s-%s.yaml" r.namespace r.name) in
    Printf.printf "  ✓  %s\n%!" path);
  Printf.printf "\nManifests written to %s/\n" dir;
  Printf.printf "Commit and push to your GitOps repo, then Argo CD will apply them.\n";
  Ok ()
;;

let report_surplus_workloads = function
  | [] -> ()
  | surplus ->
    Printf.printf
      "\nNote: %d live workload(s) in this workspace are not part of this deploy:\n"
      (List.length surplus);
    surplus
    |> List.iter (fun (id : Sol_cli_rollback.workload_identity) ->
      Printf.printf
        "  %s %s/%s\n"
        (Sol_cli_rollback.kind_resource id.kind)
        id.namespace
        id.name);
    Printf.printf
      "These may be stale from a removed/renamed service. 'sol rollback' prunes them \
       automatically when restoring a recorded release; delete them by hand if you want \
       them gone now.\n\
       %!"
;;

let report_apply_success (ctx : Sol_cli_deploy_run.context) plan results =
  results
  |> List.iter (fun r ->
    Printf.printf "  ✓  namespace %s  image %s\n\n%!" r.Sol_cli_executor.namespace r.image);
  Printf.printf "\nDone. %d service(s) deployed.\n" (List.length ctx.services);
  print_service_urls (Sol_cli_deploy_run.http_services ~ctx:ctx.execution.cluster results);
  Printf.printf "Run 'sol status' to check pod health.\n";
  report_surplus_workloads (Sol_cli_deploy_run.surplus_workloads ctx plan)
;;

let run_apply (ctx : Sol_cli_deploy_run.context) ~confirm_group_change ~loki_push_url =
  let* () = check_apply_environment ~facts:ctx.facts ~services:ctx.services in
  let* () =
    Sol_cli_deploy_run.verify_image_refs_exist ~image_refs:ctx.image_refs
    |> Sol_cli_exit.of_msg
  in
  print_header ~workspace:ctx.execution.workspace ~sha:ctx.sha ();
  let* plan = build_plan ctx ~emit_to:None in
  let* () =
    check_consumer_group_changes
      ~ctx:ctx.execution.cluster
      ~workspace:ctx.execution.workspace
      ~confirm_group_change
      plan
  in
  let* () = write_plan_if_requested ~emit_plan_to:ctx.emit_plan_to plan in
  print_planned_services plan;
  let* () = check_substrate_prerequisite ~ctx ~plan ~live:true in
  let* () = check_migration_prerequisite ~ctx ~plan ~live:true in
  record_plan ctx.run_log plan;
  Sol_cli_deploy_run.apply
    ctx
    ~push_events:
      (push_deploy_events
         ~ctx:ctx.execution.cluster
         ~target_cfg:ctx.target_cfg
         ~loki_push_url)
    ~report_success:(report_apply_success ctx plan)
    plan
  |> Result.map_error run_failed
;;

let run (req : Sol_cli_command_request.deploy_request) =
  let workspace = workspace_name () in
  let sha = req.image_tag in
  let* facts = Sol_cli_workspace_model.load_cwd () |> Sol_cli_exit.of_msg in
  let inventory = Sol_cli_workspace_model.services facts in
  let* selection =
    Sol_cli_deploy_selection.select ~scope:req.scope ~image_refs:req.image_refs inventory
    |> Sol_cli_exit.of_msg
  in
  let* resolved_config =
    Sol_cli_config.load_for_target ~target:req.target
    |> Sol_cli_exit.of_error Sol_cli_config.error_to_string
  in
  let target_cfg = resolved_config.target in
  let* deployed =
    Sol_cli_deploy_selection.apply_target
      ~target:req.target
      ~config:resolved_config
      selection
    |> Sol_cli_exit.of_msg
  in
  List.iter print_endline deployed.notes;
  let { Sol_cli_deploy_selection.requested_scope; image_refs; _ } = selection in
  let services = deployed.services in
  let registry =
    match req.registry with
    | Some r -> r
    | None ->
      (match target_cfg.registry with
       | Some r -> r
       | None -> "")
  in
  let run_log = Sol_cli_run_log.create ~prefix:"deploy" () in
  Printf.printf
    "\nRun: %s\n  log: %s/\n"
    (Sol_cli_run_log.run_id run_log)
    (Sol_cli_run_log.dir run_log);
  let emit_intent =
    match req.action with
    | Sol_cli_command_request.Deploy_dry_run { emit_to } -> emit_to
    | Sol_cli_command_request.Deploy_emit_to dir -> Some dir
    | Sol_cli_command_request.Deploy_apply -> None
  in
  let* env_target =
    Sol_cli_env_target.customer_cloud_defaults
      ~registry
      ~image_tag:sha
      ~emit_to:emit_intent
      ()
    |> Sol_cli_exit.of_msg
  in
  let secret_backend =
    Sol_cli_env_target.resolve_secret_backend ?explicit:req.secret_backend env_target
  in
  let* destination =
    Sol_cli_config.destination_of_target target_cfg |> Sol_cli_exit.of_msg
  in
  let ctx : Sol_cli_deploy_run.context =
    { execution =
        Sol_cli_execution.context
          ~cluster:(Sol_cli_kube_destination.context_of_destination destination)
          ~workspace
          ~env:target_cfg.env
          ()
    ; sha
    ; registry
    ; facts
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
    run_apply
      ctx
      ~confirm_group_change:req.confirm_group_change
      ~loki_push_url:req.loki_push_url
;;

let target_arg =
  Arg.(
    required
    & pos 0 (some Sol_cli_args.text) None
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
    & opt (some Sol_cli_args.text) None
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
    & opt (some Sol_cli_args.text) None
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
    & opt (some Sol_cli_args.text) None
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
    & opt (some Sol_cli_args.text) None
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
    & opt_all Sol_cli_args.text []
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
    & opt (some Sol_cli_args.text) None
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
    & opt (some Sol_cli_args.text) None
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
    & opt (some Sol_cli_args.text) None
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
    & opt (some Sol_cli_args.text) None
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
    & opt (some Sol_cli_args.text) None
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
    & opt (some Sol_cli_args.text) None
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
    & opt (some Sol_cli_args.text) None
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
           Sol_cli_exit.exit_on
             (let* req =
                Sol_cli_command_request.make_deploy_request
                  ~target
                  ~scope
                  ~dry_run
                  ~emit_to
                  ~emit_plan_to
                  ~image_tag
                  ~image_refs:(List.map Sol_cli_image_ref.split_flag_value raw_image_refs)
                  ~registry
                  ~secret_backend
                  ~confirm_group_change
                  ~loki_push_url
                  ~keep_releases
                  ~git_sha:Sol_cli_command_request.git_sha
                |> Sol_cli_exit.of_msg
              in
              run req))
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
