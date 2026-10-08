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

let check_apply_environment ~facts ~services =
  let* () = check_contract ~facts ~services in
  ensure_postgres_url ()
;;

let print_header ~workspace ~sha ?mode_line () =
  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  Option.iter (Printf.printf "%s\n") mode_line;
  Printf.printf "\n%!"
;;

let build_plan (input : Sol_cli_deploy_selection.Planning_input.t) =
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

let project_trusted_workload_issuer target_cfg plan =
  if
    not
      (List.exists
         (fun (service : Sol_cli_deployment_plan.service_spec) ->
            service.primitive = Sol_cli_deployment_plan.Svc)
         plan.Sol_cli_deployment_plan.services)
  then Ok plan
  else (
    match
      (Sol_cli_provider_capabilities.capabilities_of target_cfg.Sol_cli_config.provider)
        .workload_identity_issuer
        target_cfg
    with
    | Error message ->
      Error
        (Sol_cli_exit.error
           (Printf.sprintf
              "could not establish the target's trusted Kubernetes workload issuer: %s\n\
               deployments containing a svc require a target that establishes workload \
               identity"
              message))
    | Ok issuer ->
      Ok
        { plan with
          services =
            List.map
              (fun (service : Sol_cli_deployment_plan.service_spec) ->
                 match service.primitive with
                 | Svc ->
                   { service with
                     config =
                       ("SOL_TRUSTED_WORKLOAD_ISSUER", issuer)
                       :: List.remove_assoc "SOL_TRUSTED_WORKLOAD_ISSUER" service.config
                   }
                 | Worker | Fn -> service)
              plan.services
        })
;;

let planning_input_of_ctx (ctx : Sol_cli_deploy_run.context) ~emit_to
  : Sol_cli_deploy_selection.Planning_input.t
  =
  { workspace = ctx.execution.workspace
  ; registry = ctx.registry
  ; sha = ctx.sha
  ; emit_to
  ; secret_backend = ctx.secret_backend
  ; config = ctx.resolved_config
  ; facts = ctx.facts
  ; inventory = ctx.inventory
  ; requested_scope = "workspace"
  ; image_refs = ctx.image_refs
  ; services = ctx.services
  }
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

let print_contract_changes plan =
  match plan.Sol_cli_deployment_plan.contract_changes with
  | [] -> ()
  | changes ->
    Printf.printf "\nContract changes:\n%!";
    changes
    |> List.iter (fun change ->
      Printf.printf "  %s\n%!" (Sol_cli_deployment_plan.contract_change_to_string change))
;;

let run_failed msg = Sol_cli_exit.failure ("\nerror: " ^ msg)

let present_plan (ctx : Sol_cli_deploy_run.context) plan =
  (let* () = write_plan_if_requested ~emit_plan_to:ctx.emit_plan_to plan in
   print_planned_services plan;
   print_contract_changes plan;
   Ok ())
  |> Result.map_error (fun (failure : Sol_cli_exit.failure) -> failure.text)
;;

let print_guided lines = List.iter (fun line -> Printf.printf "%s\n%!" line) lines
let eprint_guided lines = List.iter (fun line -> Printf.eprintf "%s\n%!" line) lines

let setup_refusal_reason = function
  | Sol_cli_command_request.Deploy_apply -> "this run is not interactive"
  | Deploy_dry_run _ -> "this run is `--dry-run`, which changes nothing"
  | Deploy_emit_to _ -> "this run only writes manifests for another actor to apply"
;;

let allow_setup = function
  | Sol_cli_command_request.Deploy_apply -> true
  | Deploy_dry_run _ | Deploy_emit_to _ -> false
;;

let await_public_delegation ~configuration ~run ~seconds =
  Sol_cli_installation_stage.await_public_delegation
    ~configuration
    ~run
    ~seconds
    ~report:(fun line -> Printf.printf "%s\n%!" line)
    ~on_established:(fun () -> Ok ())
  |> Result.map_error Sol_cli_exit.error
;;

let print_identity_contracts ~target ~target_cfg ~configuration ~verdicts =
  Sol_cli_installation_stage.identity_contract_lines
    ~target
    ~provider:target_cfg.Sol_cli_config.provider
    ~configuration
    ~verdicts
  |> print_guided
;;

let set_up_installation ~target ~target_cfg ~configuration ~await_delegation =
  let provider = target_cfg.Sol_cli_config.provider in
  let run = Sol_cli_provider_capabilities.installation_observation ~provider in
  let* () = Cmd_cloud_tf.check_terraform () in
  let* assets = Cmd_cloud_tf.resolve_assets () in
  Printf.printf "\nSetting up the installation for %s...\n%!" target;
  let* lines =
    Sol_cli_installation_stage.reconcile ~assets ~provider ~configuration ~run ()
    |> Sol_cli_exit.of_msg
  in
  print_guided (List.map (fun line -> "  " ^ line) lines);
  let* () = await_public_delegation ~configuration ~run ~seconds:await_delegation in
  match Sol_cli_provider_capabilities.observe_installation target_cfg with
  | Error message ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf
            "the installation for %s can no longer be resolved: %s"
            target
            message))
  | Ok (_, verdicts) ->
    (match Sol_cli_installation_onboarding.state_of_verdicts verdicts with
     | Sol_cli_installation_onboarding.Present ->
       print_guided (Sol_cli_installation_onboarding.established_lines ~target);
       Ok ()
     | Sol_cli_installation_onboarding.Absent
     | Sol_cli_installation_onboarding.Partial
     | Sol_cli_installation_onboarding.Indeterminate ->
       eprint_guided
         (Sol_cli_installation_onboarding.still_unresolved_lines ~target verdicts);
       print_identity_contracts ~target ~target_cfg ~configuration ~verdicts;
       Error (Sol_cli_exit.reported ~code:1 ()))
;;

type installation_state =
  | Installation_established
  | Installation_reported

let installation_stage ~target ~target_cfg ~action ~await_delegation () =
  match Sol_cli_provider_capabilities.observe_installation target_cfg with
  | Error message ->
    eprint_guided
      (Sol_cli_installation_onboarding.undeclared_lines ~target ~reason:message);
    Ok Installation_reported
  | Ok (configuration, verdicts) ->
    let state = Sol_cli_installation_onboarding.state_of_verdicts verdicts in
    let can_set_up = allow_setup action && Sol_cli_confirm.interactive () in
    (match Sol_cli_installation_onboarding.decision ~interactive:can_set_up state with
     | Proceed -> Ok Installation_established
     | Report ->
       eprint_guided
         (Sol_cli_installation_onboarding.indeterminate_lines ~target verdicts);
       Ok Installation_reported
     | Refuse ->
       print_guided
         (Sol_cli_installation_onboarding.report_lines ~target ~configuration verdicts);
       print_identity_contracts ~target ~target_cfg ~configuration ~verdicts;
       eprint_guided
         (Sol_cli_installation_onboarding.refusal_lines
            ~target
            ~because:(setup_refusal_reason action)
            verdicts);
       Ok Installation_reported
     | Offer ->
       print_guided
         (Sol_cli_installation_onboarding.report_lines ~target ~configuration verdicts);
       print_identity_contracts ~target ~target_cfg ~configuration ~verdicts;
       if
         Sol_cli_confirm.ask
           ~question:(Printf.sprintf "Set up Sol for %s now?" target)
           ~default:true
           ~print:(fun text ->
             print_string text;
             flush stdout)
       then
         let* () =
           set_up_installation ~target ~target_cfg ~configuration ~await_delegation
         in
         Ok Installation_established
       else (
         eprint_guided
           (Sol_cli_installation_onboarding.refusal_lines
              ~target
              ~because:"you chose not to set it up"
              verdicts);
         Ok Installation_reported))
;;

let guide_installation ~target ~target_cfg ~action ~await_delegation =
  let* state = installation_stage ~target ~target_cfg ~action ~await_delegation () in
  (match state with
   | Installation_reported -> ()
   | Installation_established ->
     print_guided (Sol_cli_installation_onboarding.present_lines ~target));
  Ok ()
;;

let guide_installation_of_ctx ~ctx ~action ~await_delegation =
  guide_installation
    ~target:ctx.Sol_cli_deploy_run.target_name
    ~target_cfg:ctx.Sol_cli_deploy_run.target_cfg
    ~action
    ~await_delegation
;;

let destination_output_lines ~infra_dir =
  let wanted =
    [ "deploy_kubeconfig_command"
    ; "deploy_kube_context"
    ; "kubeconfig_command"
    ; "kube_context"
    ]
  in
  match Sol_cli_terraform.output_json ~chdir:infra_dir () with
  | Error _ -> []
  | Ok output ->
    (match Sol_cli_terraform_outputs.displayable output.stdout with
     | Error _ -> []
     | Ok outputs ->
       outputs
       |> List.filter (fun (name, _) -> List.mem name wanted)
       |> List.map Sol_cli_terraform_outputs.line)
;;

let no_deploy_identity_lines ~target ~infra_dir =
  [ Printf.sprintf
      "The environment for %s is provisioned, but this run cannot reach its cluster as a \
       deploy identity:"
      target
  ; "  this provider declares no deploy identity, and Sol does not reach a cluster as the"
  ; "  provisioning identity it has just used (DEC-034)."
  ; ""
  ; "One action required — configure kubectl as the identity that deploys to this target,"
  ; "then name the context it writes as this target's kube_context:"
  ]
  @ List.map (fun line -> "  " ^ line) (destination_output_lines ~infra_dir)
  @ [ ""; Printf.sprintf "Then re-run `sol deploy %s`." target ]
;;

let environment_destination ~target ~cluster ~infra_dir =
  match cluster with
  | None ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf
            "the environment for %s was provisioned, but Sol cannot read back the \
             cluster it created from Terraform's outputs, so this run cannot name the \
             cluster it would deploy to. Observe it with `sol cloud apply %s --plan` and \
             re-run."
            target
            target))
  | Some cluster ->
    (match cluster.Sol_cli_cluster.deploy_access () with
     | Ok (Some destination) -> Ok destination
     | Ok None ->
       eprint_guided (no_deploy_identity_lines ~target ~infra_dir);
       Error (Sol_cli_exit.reported ~code:1 ())
     | Error message -> Error (Sol_cli_exit.error message))
;;

let environment_refusal_lines ~target ~because =
  [ Printf.sprintf
      "The environment for %s is not provisioned yet, and Sol will not create it in this \
       run: %s."
      target
      because
  ; ""
  ; "Sol does this for you on a run that changes things: reconcile the environment for \
     this"
  ; "target — network, cluster, database and platform — and establish this run's own \
     cluster"
  ; "access."
  ; ""
  ; "Create it with:"
  ; Printf.sprintf "  sol cloud apply %s" target
  ; Printf.sprintf
      "then name the context that command prints as this target's kube_context, and run \
       `sol deploy %s` again."
      target
  ]
;;

let environment_stage ~target ~run_log ~action () =
  if not (allow_setup action)
  then (
    eprint_guided
      (environment_refusal_lines ~target ~because:(setup_refusal_reason action));
    Error (Sol_cli_exit.reported ~code:1 ()))
  else
    let* () = Cmd_cloud_tf.check_terraform () in
    let* assets = Cmd_cloud_tf.resolve_assets () in
    print_guided
      [ ""
      ; Printf.sprintf
          "Sol does this for you: reconcile the environment for %s — network, cluster, \
           database and platform — from the durable installation, and establish this \
           run's own cluster access."
          target
      ];
    match
      Sol_cli_environment_stage.apply ~assets ~run_log ~target ~var_file:None ~vars:[] ()
    with
    | Ok (Sol_cli_environment_stage.Applied { cluster; infra_dir }) ->
      print_guided [ Printf.sprintf "The environment for %s is provisioned." target ];
      environment_destination ~target ~cluster ~infra_dir
    | Ok (Sol_cli_environment_stage.Apply_failed { failure; _ }) ->
      Error
        (Sol_cli_exit.failure
           ("\n" ^ Sol_cli_environment_stage.failure_to_string failure))
    | Error failure ->
      Error
        (Sol_cli_exit.failure
           ("\n" ^ Sol_cli_environment_stage.failure_to_string failure))
;;

let first_run ~target ~target_cfg ~action ~await_delegation ~run_log () =
  print_guided
    [ ""
    ; Printf.sprintf
        "This target names no Kubernetes destination Sol can reach from here, so this is \
         the first run for %s:"
        target
    ];
  let* () =
    match installation_stage ~target ~target_cfg ~action ~await_delegation () with
    | Ok Installation_established ->
      print_guided (Sol_cli_installation_onboarding.observed_lines ~target);
      Ok ()
    | Ok Installation_reported -> Error (Sol_cli_exit.reported ~code:1 ())
    | Error exit -> Error exit
  in
  environment_stage ~target ~run_log ~action ()
;;

let destination_or_environment_stage
      ~planning
      ~target
      ~run_log
      ~action
      ~await_delegation
      ()
  =
  let target_cfg =
    planning.Sol_cli_deploy_selection.Planning_input.config.Sol_cli_config.target
  in
  let declared_context =
    match target_cfg.Sol_cli_config.kube_context with
    | Some context -> not (Sol_cli_string.is_blank context)
    | None -> false
  in
  let first_run () =
    let* destination =
      first_run ~target ~target_cfg ~action ~await_delegation ~run_log ()
    in
    Ok (destination, true)
  in
  match Sol_cli_config.destination_of_target target_cfg with
  | Ok destination when not (allow_setup action) -> Ok (destination, false)
  | Ok destination when Sol_cli_target_report.context_is_configured destination ->
    Ok (destination, false)
  | Ok _ -> first_run ()
  | Error message when declared_context -> Error (Sol_cli_exit.error message)
  | Error _ when allow_setup action -> first_run ()
  | Error message ->
    let* () = guide_installation ~target ~target_cfg ~action ~await_delegation in
    Error (Sol_cli_exit.error message)
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

let run_dry_run (ctx : Sol_cli_deploy_run.context) ~emit_to ~await_delegation =
  print_header ~workspace:ctx.execution.workspace ~sha:ctx.sha ~mode_line:"(dry-run)" ();
  let* plan = build_plan (planning_input_of_ctx ctx ~emit_to) in
  let* plan = project_trusted_workload_issuer ctx.target_cfg plan in
  Sol_cli_deploy_run.run_offline
    ctx
    ~phase:"dry-run"
    ~mode:Sol_cli_executor.Dry_run
    ~present_plan:(present_plan ctx)
    ~on_substrate_refused:(fun _ ->
      guide_installation_of_ctx
        ~ctx
        ~action:(Sol_cli_command_request.Deploy_dry_run { emit_to })
        ~await_delegation
      |> ignore)
    plan
  |> Result.map (fun _ -> ())
  |> Result.map_error run_failed
;;

let run_emit (ctx : Sol_cli_deploy_run.context) ~dir =
  print_header
    ~workspace:ctx.execution.workspace
    ~sha:ctx.sha
    ~mode_line:(Printf.sprintf "emit-to: %s" dir)
    ();
  let* plan = build_plan (planning_input_of_ctx ctx ~emit_to:(Some dir)) in
  let* plan = project_trusted_workload_issuer ctx.target_cfg plan in
  let* results =
    Sol_cli_deploy_run.run_offline
      ctx
      ~phase:"emit"
      ~mode:(Sol_cli_executor.Emit_to dir)
      ~present_plan:(present_plan ctx)
      ~on_substrate_refused:(fun _ -> ())
      plan
    |> Result.map_error run_failed
  in
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

let namespace_of_facts ~workspace (facts : Sol_cli_workspace_model.t) =
  Sol_cli_workspace_model.workloads facts
  |> Sol_cli_result.map_list (fun (workload : Sol_cli_workspace_model.workload) ->
    let open Result.Syntax in
    let* unit = Sol_cli_authorization_reconcile.unit_name workload.service in
    Sol_cli_deployment_plan.namespace_name
      ~workspace
      ~domain:workload.service.Sol_cli_manifest.domain
    |> Result.map (fun namespace -> unit, namespace))
  |> Result.map (fun pairs -> fun unit -> List.assoc_opt unit pairs)
;;

let verify_effective_access
      (planning : Sol_cli_deploy_selection.Planning_input.t)
      ~target_cfg
  =
  let open Result.Syntax in
  let* grants = Sol_cli_authorization_reconcile.desired planning.facts in
  let* namespace_of = namespace_of_facts ~workspace:planning.workspace planning.facts in
  let* workloads = Sol_cli_authorization_reconcile.workloads ~grants ~namespace_of in
  (Sol_cli_provider_capabilities.capabilities_of target_cfg.Sol_cli_config.provider)
    .authorization_effective_access
    target_cfg
    workloads
;;

let check_effective_access
      (planning : Sol_cli_deploy_selection.Planning_input.t)
      ~target_cfg
  =
  verify_effective_access planning ~target_cfg
  |> Sol_cli_exit.of_msg
  |> Result.map_error (fun (failure : Sol_cli_exit.failure) -> failure.text)
;;

let run_apply
      ~planning
      ~context_of
      ~target
      ~run_log
      ~confirm_group_change
      ~loki_push_url
      ~await_delegation
      ()
  =
  let* () =
    check_apply_environment
      ~facts:planning.Sol_cli_deploy_selection.Planning_input.facts
      ~services:planning.Sol_cli_deploy_selection.Planning_input.services
  in
  let* () =
    Sol_cli_deploy_run.verify_image_refs_exist
      ~image_refs:planning.Sol_cli_deploy_selection.Planning_input.image_refs
    |> Sol_cli_exit.of_msg
  in
  print_header
    ~workspace:planning.Sol_cli_deploy_selection.Planning_input.workspace
    ~sha:planning.Sol_cli_deploy_selection.Planning_input.sha
    ();
  let* plan = build_plan planning in
  let* destination, established =
    destination_or_environment_stage
      ~planning
      ~target
      ~run_log
      ~action:Sol_cli_command_request.Deploy_apply
      ~await_delegation
      ()
  in
  let ctx : Sol_cli_deploy_run.context = context_of ~destination in
  let* plan = project_trusted_workload_issuer ctx.target_cfg plan in
  Sol_cli_deploy_run.apply
    ctx
    ~present_plan:(present_plan ctx)
    ~effective_access:(fun () ->
      check_effective_access planning ~target_cfg:ctx.target_cfg)
    ~on_substrate_refused:(fun _ ->
      if not established
      then
        guide_installation_of_ctx
          ~ctx
          ~action:Sol_cli_command_request.Deploy_apply
          ~await_delegation
        |> ignore)
    ~confirm_group_change
    ~push_events:
      (push_deploy_events
         ~ctx:ctx.execution.cluster
         ~target_cfg:ctx.target_cfg
         ~loki_push_url)
    ~report_success:(report_apply_success ctx)
    plan
  |> Result.map_error run_failed
;;

let run (req : Sol_cli_command_request.deploy_request) =
  let workspace = workspace_name () in
  let sha = req.image_tag in
  let* facts = Sol_cli_workspace_model.load_cwd () |> Sol_cli_exit.of_msg in
  let inventory = Sol_cli_workspace_model.services facts in
  let* selection =
    Sol_cli_deploy_selection.select ~image_refs:req.image_refs inventory
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
  let { Sol_cli_deploy_selection.image_refs; _ } = selection in
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
  let await_delegation = Option.value req.await_delegation ~default:300 in
  let planning : Sol_cli_deploy_selection.Planning_input.t =
    { workspace
    ; registry
    ; sha
    ; emit_to = emit_intent
    ; secret_backend
    ; config = resolved_config
    ; facts
    ; inventory
    ; requested_scope = "workspace"
    ; image_refs
    ; services
    }
  in
  let context_of ~destination : Sol_cli_deploy_run.context =
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
    ; target_name = req.target
    ; run_log
    ; keep_releases = req.keep_releases
    }
  in
  match req.action with
  | Sol_cli_command_request.Deploy_apply ->
    run_apply
      ~planning
      ~context_of
      ~target:req.target
      ~run_log
      ~confirm_group_change:req.confirm_group_change
      ~loki_push_url:req.loki_push_url
      ~await_delegation
      ()
  | Deploy_dry_run { emit_to } ->
    let* destination, _ =
      destination_or_environment_stage
        ~planning
        ~target:req.target
        ~run_log
        ~action:(Sol_cli_command_request.Deploy_dry_run { emit_to })
        ~await_delegation
        ()
    in
    run_dry_run (context_of ~destination) ~emit_to ~await_delegation
  | Deploy_emit_to dir ->
    let* destination, _ =
      destination_or_environment_stage
        ~planning
        ~target:req.target
        ~run_log
        ~action:(Sol_cli_command_request.Deploy_emit_to dir)
        ~await_delegation
        ()
    in
    run_emit (context_of ~destination) ~dir
;;

let target_arg =
  Sol_cli_target_arg.positional
    ~doc:
      "Deployment target path: <env>/<provider>/<region>, e.g. dev/aws/us-east-1 — same \
       convention as 'sol plan'. Resolves sol.yml, then the environment and target in \
       sol/environments.yml, for registry/env defaults. Unlike 'sol up' (local-only, no \
       target concept), this is required."
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
           destination decides: a direct or local deploy uses the operator-owned live \
           Secret ('kubernetes-live'; Sol emits no Secret for it, so populate it with \
           'sol secret set'), while a GitOps target writes a redacted \
           'kubernetes-placeholder' Secret. Pass 'kubernetes-placeholder' to force a \
           redacted Secret, or 'external-secrets' (requires --emit-to and \
           --secret-store-ref) to emit an ExternalSecret CRD for the External Secrets \
           Operator instead.")
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
          "Kind of the secret store reference. One of 'SecretStore' (namespace-scoped) \
           or 'ClusterSecretStore' (default).")
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
          "How often ESO should sync the secret from the external store (default: 1h). A \
           Go duration: one or more number/unit groups, e.g. '1h', '30m', '5m', '1h30m', \
           '500ms' (units: ns, us, µs, ms, s, m, h).")
;;

let secret_backend_term =
  let build backend store_ref store_kind key_prefix refresh_interval emit_to =
    match
      Sol_cli_secret_backend.emission_backend
        ~emit_to
        ~backend
        ~store_ref
        ~store_kind
        ~key_prefix
        ~refresh_interval
    with
    | Ok backend -> `Ok backend
    | Error message -> `Error (true, message)
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

let await_delegation_arg =
  Arg.(
    value
    & opt (some int) None
    & info
        [ "await-delegation" ]
        ~docv:"SECONDS"
        ~doc:
          "Bound the wait for the domain this target serves to answer with NS records \
           from a public resolver during the inline first-run setup, in five-second \
           checks. Omitted, that wait runs for up to 300 seconds; 0 disables it. The \
           exact records to add are printed either way, and an unqueryable resolver is \
           UNKNOWN rather than a silent success.")
;;

let man =
  [ `S Manpage.s_description
  ; `P
      "Like 'sol up' without the build step: the images must already be in the registry, \
       addressed by --image-tag or by an immutable --image-ref."
  ; `P
      "The first run for an account is guided in place (DEC-057 §2): when this deploy \
       cannot reach the target's cluster, Sol observes the target's durable installation \
       at the provider — never inferring it from configuration — and reports what it \
       found. An installation that is not established is reported with the prerequisites \
       that are missing, the work Sol would do to set it up, and the one external action \
       the operator may have to take (today, the DNS delegation), and Sol offers to set \
       it up without a separate administrative command. An account that already has an \
       installation is deployed to without any one-time setup and without a prompt."
  ; `P
      "Every prerequisite is an observation: Established, Unmet (the provider answered \
       that it is not there) or UNKNOWN (Sol could not look). A refused or \
       unauthenticated provider answer is UNKNOWN, never treated as an absent \
       prerequisite, because a deploy identity is not required to be able to read the \
       durable resources; UNKNOWN is reported and never promoted to healthy (DEC-052)."
  ; `P
      "A run that is not interactive, or that changes nothing (--dry-run, --emit-to), \
       never prompts and never sets an installation up: it reports the same observation \
       and the command that establishes it, so a CI run fails with an explanation \
       instead of hanging or silently skipping the installation."
  ; `S "EXIT STATUS"
  ; `P
      "0 -- the deployment was applied (or emitted) and verified as the selected profile \
       requires."
  ; `P
      "1 -- the run failed: a prerequisite is unmet, unknown or was refused; a migration \
       is not applied; the deployment did not converge; or the operator declined (or was \
       not asked) to set an unestablished installation up. The reason is named on \
       stderr, and nothing is assumed healthy."
  ; `P "No other code is used by this command."
  ]
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
          service-path filter — 'sol up' is local-only and has no target to resolve. A \
          first run against an uninstalled account is guided in place rather than \
          requiring 'sol cloud bootstrap' first."
       ~man)
    Term.(
      const
        (fun
            target
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
             await_delegation
           ->
           Sol_cli_exit.exit_on
             (let* req =
                Sol_cli_command_request.make_deploy_request
                  ~target
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
                  ~await_delegation
                  ~git_sha:Sol_cli_command_request.git_sha
                |> Sol_cli_exit.of_msg
              in
              run req))
      $ target_arg
      $ dry_run_flag
      $ emit_to_arg
      $ emit_plan_to_arg
      $ image_tag_arg
      $ image_ref_arg
      $ registry_arg
      $ secret_backend_term
      $ confirm_group_change_flag
      $ loki_push_url_arg
      $ keep_releases_arg
      $ await_delegation_arg)
;;
