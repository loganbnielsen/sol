open Result.Syntax

type context =
  { execution : Sol_cli_execution.context
  ; sha : string
  ; registry : string
  ; facts : Sol_cli_workspace_model.t
  ; secret_backend : Sol_cli_manifest.secret_backend
  ; emit_plan_to : string option
  ; target_cfg : Sol_cli_config.target
  ; resolved_config : Sol_cli_config.t
  ; services : Sol_cli_manifest.service list
  ; inventory : Sol_cli_manifest.service list
  ; image_refs : (string * string) list
  ; requested_scope : string
  ; target_name : string
  ; run_log : Sol_cli_run_log.t
  ; keep_releases : int
  }

let http_services ~ctx (results : Sol_cli_executor.result list) =
  let deployed = results |> List.map (fun r -> r.Sol_cli_executor.name) in
  let cluster_ip_services ns =
    let jsonpath = "{.items[?(@.spec.type==\"ClusterIP\")].metadata.name}" in
    match
      Sol_cli_kubectl.get_raw
        ~ctx
        ~args:[ "get"; "svc"; "-n"; ns; "-o"; "jsonpath=" ^ jsonpath ]
    with
    | Ok r ->
      String.split_on_char ' ' r.stdout |> List.filter_map Sol_cli_string.non_blank
    | Error _ -> []
  in
  let serves_port_80 ns name =
    match
      Sol_cli_kubectl.get
        ~ctx
        ~resource:"svc"
        ~name
        ~namespace:ns
        ~output:"jsonpath={.spec.ports[?(@.port==80)].port}"
    with
    | Ok r -> Option.is_some (Sol_cli_string.non_blank r.stdout)
    | Error _ -> false
  in
  results
  |> List.map (fun r -> r.Sol_cli_executor.namespace)
  |> List.sort_uniq String.compare
  |> List.concat_map (fun ns ->
    cluster_ip_services ns
    |> List.filter (fun name -> List.mem name deployed && serves_port_80 ns name))
;;

let verify_image_refs_exist ~image_refs =
  match
    image_refs
    |> List.find_opt (fun (_, ref) -> not (Sol_cli_docker.manifest_exists ~image_ref:ref))
  with
  | None -> Ok ()
  | Some (service, ref) ->
    Error
      (Printf.sprintf
         "--image-ref for service %s was not found in its registry: %s\n\
         \  (docker manifest inspect failed; check the repository, digest and registry \
          credentials)\n\
         \  Nothing was applied."
         service
         ref)
;;

let run_plan_result ctx ~phase ~mode ?before_apply plan =
  Sol_cli_run_log.run_task ctx.run_log ~name:phase (fun () ->
    Sol_cli_factory.execute
      ctx.execution
      ~mode
      ~secret_backend:ctx.secret_backend
      ?before_apply
      plan)
;;

type gate_failure =
  | Refused of string
  | Failed of string

let plan_workloads (plan : Sol_cli_deployment_plan.t) =
  List.map
    (fun (spec : Sol_cli_deployment_plan.service_spec) ->
       ( Sol_cli_deployment_plan.namespace_to_string spec.namespace
       , Sol_cli_kubernetes_name.k8s_name_to_string spec.k8s_name ))
    plan.Sol_cli_deployment_plan.services
;;

let migration_prerequisite ctx ~plan ~live =
  match plan.Sol_cli_deployment_plan.profile with
  | None -> Ok ()
  | Some _ ->
    let dir =
      Filename.concat ctx.facts.Sol_cli_workspace_model.root Sol_cli_migration.default_dir
    in
    if not live
    then (
      match Sol_cli_migration.required_if_present ~dir with
      | Ok [] | Error _ -> Ok ()
      | Ok _ ->
        Sol_cli_report.app
          "Migrations: NOT verified -- a side-effect-free run creates no status Job. The \
           applied migration set is only checked against the live cluster by a real \
           deploy (before any workload moves).";
        Ok ())
    else
      let* () =
        Sol_cli_substrate.ensure
          ~ctx:ctx.execution.cluster
          ~namespaces:(Sol_cli_substrate.namespaces plan)
          ~workloads:(plan_workloads plan)
        |> Result.map_error (fun message -> Refused message)
      in
      Sol_cli_migration_gate.reconcile_operator_bindings
        ~ctx:ctx.execution.cluster
        ~workspace:ctx.execution.workspace
        ~services:ctx.inventory;
      (match
         Sol_cli_migration_gate.verify
           ~ctx:ctx.execution.cluster
           ~workspace:ctx.execution.workspace
           ~dir
           ~services:ctx.inventory
       with
       | Sol_cli_migration_gate.No_migrations -> Ok ()
       | Sol_cli_migration_gate.Satisfied applied ->
         Sol_cli_report.app
           "Migrations: OK -- %d declared migration(s) present in schema_migrations"
           (List.length applied);
         Ok ()
       | Sol_cli_migration_gate.Unsatisfied missing ->
         Error
           (Failed
              (Printf.sprintf
                 "\n\
                  error: the required migration set is not applied. Missing: %s\n\
                 \  Migrations are workspace-wide, so this is the same set whatever \
                  scope the deploy selected. Run `sol migrate apply %s`, then deploy \
                  again."
                 (String.concat ", " (List.map Sol_cli_migration.to_string missing))
                 ctx.target_name))
       | Sol_cli_migration_gate.Drifted drifted ->
         Error
           (Failed
              (Printf.sprintf
                 "\n\
                  error: an already-applied migration no longer matches the file this \
                  revision carries, so the applied schema record and the deployable \
                  revision disagree:\n\
                  %s\n\
                 \  Restore each file to the content that was applied, or put the change \
                  in a new migration and apply it with `sol migrate apply %s`. Deploying \
                  while they disagree would record a boundary whose schema is one of the \
                  two, not both."
                 (String.concat
                    "\n"
                    (List.map
                       (fun d -> "  - " ^ Sol_cli_migration.drift_message d)
                       drifted))
                 ctx.target_name))
       | Sol_cli_migration_gate.Unavailable reason ->
         Error
           (Failed
              (Printf.sprintf
                 "\n\
                  error: cannot verify the required migration state: %s\n\
                 \  A deploy against the production profile fails closed rather than \
                  assume the schema is compatible. Migrations are workspace-wide -- the \
                  deploy's scope does not select them -- so `sol migrate apply %s` \
                  checks the same required set this deploy did (it reports the applied \
                  set). Run it, then deploy again."
                 reason
                 ctx.target_name)))
;;

let substrate_prerequisite ctx ~plan ~live =
  let namespaces = Sol_cli_substrate.namespaces plan in
  if namespaces = []
  then Ok ()
  else if live
  then
    Sol_cli_substrate.ensure
      ~ctx:ctx.execution.cluster
      ~namespaces
      ~workloads:(plan_workloads plan)
    |> Result.map_error (fun message -> Refused message)
  else
    Sol_cli_substrate.established ~ctx:ctx.execution.cluster ~namespaces
    |> Result.map_error (fun message -> Refused message)
;;

let deploy_events
      ~workspace
      ~(target_cfg : Sol_cli_config.target)
      ~deployment_id
      ?release_id
      plan
  =
  let release_id =
    Option.value release_id ~default:plan.Sol_cli_deployment_plan.release_id
  in
  plan.Sol_cli_deployment_plan.services
  |> List.map (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    { Sol_cli_deploy_event.workspace
    ; env = target_cfg.env
    ; domain = spec.domain
    ; service = Sol_cli_kubernetes_name.k8s_name_to_string spec.k8s_name
    ; primitive =
        Sol_cli_manifest.primitive_label
          (match spec.primitive with
           | Sol_cli_deployment_plan.Svc -> Sol_cli_manifest.Svc
           | Worker -> Sol_cli_manifest.Worker
           | Fn -> Sol_cli_manifest.Fn)
    ; release_id
    ; deployment_id
    })
;;

let confirm_consumer_groups ~ctx ~workspace ~confirm_group_change plan =
  Sol_cli_deployment_state.check_removed_groups
    ~ctx
    ~workspace
    ~confirm_group_change
    ~next:
      (List.map
         Sol_cli_plan_ids.Consumer_group.to_string
         plan.Sol_cli_deployment_plan.consumer_groups)
;;

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

let record_release_and_prune ctx ~previous ~retained plan =
  let cluster = ctx.execution.cluster in
  let workspace = ctx.execution.workspace in
  match
    Sol_cli_release_store.record_plan
      ~ctx:cluster
      ~apply_mode:Sol_cli_release.Direct
      ~retained
      plan
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
  | Ok boundary_id ->
    (match
       Sol_cli_release_retention.with_retention
         ~ctx:cluster
         ~workspace
         ~keep:ctx.keep_releases
         ~current:boundary_id
         ~previous
     with
     | Pruned [] -> ()
     | Pruned pruned ->
       Sol_cli_report.app
         "Pruned %d release record(s) beyond the last %d."
         (List.length pruned)
         ctx.keep_releases
     | Deferred reason -> Sol_cli_report.app "Retention: not run -- %s" reason
     | Failed msg -> Sol_cli_report.warn "warning: could not prune old releases: %s" msg);
    Ok ()
;;

let surplus_workloads ctx (plan : Sol_cli_deployment_plan.t) =
  if not (String.equal ctx.requested_scope "workspace")
  then []
  else (
    match
      Sol_cli_rollback.live_workloads
        ~ctx:ctx.execution.cluster
        ~workspace:ctx.execution.workspace
    with
    | Error _ -> []
    | Ok live ->
      Sol_cli_rollback.unexpected_workloads ~expected:plan.services ~live |> List.map fst)
;;

let execute_deployment_attempt ctx ~before_apply ~push_events ~release_id ~finish plan =
  let attempt = Sol_cli_deployment_attempt.start () in
  let applied =
    run_plan_result ctx ~phase:"apply" ~mode:Sol_cli_executor.Apply ~before_apply plan
  in
  let completed = Result.bind applied finish in
  let outcome = Sol_cli_deployment_attempt.outcome_of completed in
  let recorded =
    Sol_cli_deployment_attempt.record
      ~ctx:ctx.execution.cluster
      ~target:(Some ctx.target_name)
      ~release_id
      plan
      attempt
      outcome
  in
  (match outcome with
   | Sol_cli_deployment.Applied when recorded ->
     push_events
       (deploy_events
          ~workspace:ctx.execution.workspace
          ~target_cfg:ctx.target_cfg
          ~deployment_id:(Sol_cli_deployment_attempt.deployment_id attempt)
          ~release_id
          plan)
   | _ -> ());
  completed
;;

let contract_reconciliation ctx (plan : Sol_cli_deployment_plan.t) =
  let workspace = ctx.facts.Sol_cli_workspace_model.root in
  let production =
    match plan.Sol_cli_deployment_plan.profile with
    | Some { profile = Sol_cli_profile.Production_single_region; _ } -> true
    | None -> false
  in
  if not (Sol_cli_contract.has_projection ~workspace)
  then Ok ()
  else
    Sol_cli_contract.reconciliation_images plan.Sol_cli_deployment_plan.services
    |> Sol_cli_result.map_list (fun (namespace, image) ->
      Sol_cli_contract.reconcile_in_destination
        ~ctx:ctx.execution.cluster
        ~production
        ~namespace
        ~image)
    |> Result.map (fun _ -> ())
;;

let apply ctx ~push_events ~report_success ~confirm_group_change plan =
  Sol_cli_boundary_lease.with_boundary_lease
    ~ctx:ctx.execution.cluster
    ~workspace:ctx.execution.workspace
    ~holder:Sol_cli_boundary_lease.Deploy
    ~ttl:Sol_cli_boundary_lease.default_ttl_s
    ~wait_s:0.
    (fun lease ->
       let* () = Sol_cli_boundary_lease.ensure_held lease in
       let* () =
         confirm_consumer_groups
           ~ctx:ctx.execution.cluster
           ~workspace:ctx.execution.workspace
           ~confirm_group_change
           plan
       in
       let previous = read_previous_release ctx in
       let* retained =
         Sol_cli_release_store.retained_for_plan
           ~ctx:ctx.execution.cluster
           ~workspace:ctx.execution.workspace
           plan
       in
       let boundary =
         Sol_cli_release.of_plan_with_boundary
           ~apply_mode:Sol_cli_release.Direct
           ~retained
           plan
       in
       let* release_id = Sol_cli_release_id.of_string boundary.release_id in
       let* () = contract_reconciliation ctx plan in
       execute_deployment_attempt
         ctx
         ~before_apply:(fun _ -> Sol_cli_boundary_lease.ensure_held lease)
         ~push_events
         ~release_id
         ~finish:(fun results ->
           Sol_cli_release.finish_deployment
             ~record_release:(fun () ->
               let* () = Sol_cli_boundary_lease.ensure_held lease in
               let* () = record_release_and_prune ctx ~previous ~retained plan in
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
                          plan.consumer_groups
                    }))
             ~report_success:(fun () -> report_success results))
         plan)
;;
