type service_execution = {
  k8s_name : string;
  namespace : string;
  push_image : string;
  context : string;
  dockerfile : string;
  source_dir : string;
}

type post_deploy_summary = {
  deployed_count : int;
  pending_migrations : int;
}

let push_registry = "localhost:5000"

let build_context_dir ~repo_root =
  repo_root ^ ".docker-ctx"

let local_plan ~workspace ~sha services =
  let env_target = Sol_cli_env_target.local_defaults ~image_tag:sha in
  let env = Sol_cli_env_target.to_env_config ~name:workspace env_target in
  Sol_cli_deployment_plan.of_services_result ~workspace ~env services

let manifest_primitive = function
  | Sol_cli_deployment_plan.Svc    -> Sol_cli_manifest.Svc
  | Sol_cli_deployment_plan.Worker -> Sol_cli_manifest.Worker
  | Sol_cli_deployment_plan.Fn     -> Sol_cli_manifest.Fn

let push_image_ref ~workspace ~sha spec =
  Sol_cli_deployment_plan.image_ref
    ~registry:push_registry ~workspace
    ~k8s_name:spec.Sol_cli_deployment_plan.k8s_name ~tag:sha

let service_execution ~workspace ~ctx_dir ~sha
    (spec : Sol_cli_deployment_plan.service_spec) =
  {
    k8s_name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name;
    namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace;
    push_image = push_image_ref ~workspace ~sha spec;
    context = ctx_dir;
    dockerfile = Printf.sprintf "%s/%s/Dockerfile" ctx_dir spec.source_dir;
    source_dir = spec.source_dir;
  }

let dry_run_spec ~workspace ~sha spec =
  { spec with Sol_cli_deployment_plan.image = push_image_ref ~workspace ~sha spec }

let prepare_build_context ~repo_root =
  let ctx_dir = build_context_dir ~repo_root in
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
  let rsync_cmd = Printf.sprintf
    "rsync -a --copy-links --exclude='_build' --exclude='.git' %s/ %s"
    (Filename.quote repo_root) (Filename.quote ctx_dir) in
  if Sys.command rsync_cmd = 0 then Ok ctx_dir
  else Error "failed to copy workspace for docker build context"

let remove_build_context ~ctx_dir =
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)))

let build_image exec =
  match Sol_cli_docker.build
          ~tag:exec.push_image ~dockerfile:exec.dockerfile ~context:exec.context with
  | Error e ->
    Error (Printf.sprintf "docker build failed: %s\n%s"
      exec.source_dir (Sol_cli_process.error_to_string e))
  | Ok () -> Ok ()

let push_image exec =
  match Sol_cli_docker.push ~image_ref:exec.push_image with
  | Error e ->
    Error (Printf.sprintf "docker push failed: %s\n%s"
      exec.push_image (Sol_cli_process.error_to_string e))
  | Ok () -> Ok ()

let apply_service_manifest ~workspace ~dry_run spec =
  try Ok (Sol_cli_executor.local ~workspace ~dry_run spec)
  with Failure msg -> Error msg

let wait_for_service_rollout spec exec =
  match spec.Sol_cli_deployment_plan.primitive with
  | Sol_cli_deployment_plan.Fn -> Ok ()
  | Sol_cli_deployment_plan.Svc
  | Sol_cli_deployment_plan.Worker ->
    match Sol_cli_kubectl.rollout_status
            ~kind_name:("deployment/" ^ exec.k8s_name) ~namespace:exec.namespace with
    | Ok r when r.Sol_cli_process.exit_code = 0 -> Ok ()
    | _ ->
      let pod_expectation =
        Sol_cli_status.pod_expectation_of_primitive (manifest_primitive spec.primitive)
      in
      match Sol_cli_rollout_diagnosis.diagnose_service_live
              ~pod_expectation ~ns:exec.namespace ~service_name:spec.source_name
              ~k8s_name:exec.k8s_name () with
      | Some d -> Error d
      | None -> Error (Printf.sprintf "rollout failed: %s/%s" exec.namespace exec.k8s_name)

let post_deploy_summary ~cwd plan =
  {
    deployed_count = List.length plan.Sol_cli_deployment_plan.services;
    pending_migrations = Sol_cli_workspace.pending_migration_count ~dir:cwd;
  }

let record_applied ~workspace ~sha plan =
  Sol_cli_deployment_state.record_outcome workspace
    (Sol_cli_deployment_state.Applied {
      namespace = "default";
      name = workspace;
      image = sha;
      consumer_groups = List.map Sol_cli_plan_ids.Consumer_group.to_string
                          plan.Sol_cli_deployment_plan.consumer_groups;
    })
