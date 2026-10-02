let release_id_of_test =
  Sol_cli_release_id.of_content { workspace = "test"; environment = None; workloads = [] }
;;

let ok = function
  | Ok r -> r
  | Error e -> Alcotest.fail e
;;

let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let namespace ~workspace ~domain =
  match Sol_cli_deployment_plan.namespace_result ~workspace ~domain with
  | Ok namespace -> namespace
  | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let cpu s =
  match Sol_cli_toml.cpu_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message
;;

let memory s =
  match Sol_cli_toml.memory_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message
;;

let contains haystack needle = Sol_cli_string.contains ~needle haystack

let assert_contains label haystack needle =
  Alcotest.(check bool)
    (Printf.sprintf "%s: contains %S" label needle)
    true
    (contains haystack needle)
;;

let assert_absent label haystack needle =
  Alcotest.(check bool)
    (Printf.sprintf "%s: absent %S" label needle)
    false
    (contains haystack needle)
;;

let svc_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "payments"
  ; source_name = "charge_svc"
  ; k8s_name = k8s_name "charge-svc"
  ; namespace = namespace ~workspace:"myapp" ~domain:"payments"
  ; primitive = Sol_cli_deployment_plan.Svc
  ; source_dir = "app/payments/charge_svc"
  ; image = "registry.example.com/myapp/charge-svc:abc123"
  ; config = []
  ; secrets = []
  ; volumes = []
  ; schedule = None
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu = cpu "100m"
  ; memory = memory "128Mi"
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = []
  ; called_by = []
  ; extra_labels = []
  ; progressive_delivery = None
  }
;;

let worker_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "comms"
  ; source_name = "notify_worker"
  ; k8s_name = k8s_name "notify-worker"
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; namespace = namespace ~workspace:"myapp" ~domain:"comms"
  ; primitive = Sol_cli_deployment_plan.Worker
  ; source_dir = "app/comms/notify_worker"
  ; image = "registry.example.com/myapp/notify-worker:abc123"
  ; config = []
  ; secrets = []
  ; volumes = []
  ; schedule = None
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu = cpu "100m"
  ; memory = memory "128Mi"
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = []
  ; called_by = []
  ; extra_labels = []
  ; progressive_delivery = None
  }
;;

let fn_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "billing"
  ; source_name = "invoice_fn"
  ; k8s_name = k8s_name "invoice-fn"
  ; namespace = namespace ~workspace:"myapp" ~domain:"billing"
  ; primitive = Sol_cli_deployment_plan.Fn
  ; source_dir = "app/billing/invoice_fn"
  ; image = "registry.example.com/myapp/invoice-fn:abc123"
  ; config = []
  ; secrets = []
  ; volumes = []
  ; schedule = Some "0 9 * * 1"
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu = cpu "100m"
  ; memory = memory "128Mi"
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = []
  ; called_by = []
  ; extra_labels = []
  ; progressive_delivery = None
  }
;;

let local_env : Sol_cli_deployment_plan.env_config =
  { name = "local"
  ; mode = Sol_cli_deployment_plan.Local
  ; registry = "sol-registry:5000"
  ; image_tag = "dev"
  ; env = None
  ; region = None
  ; base_domain = None
  ; cluster_issuer = "letsencrypt-prod"
  ; secret_backend = Sol_cli_manifest.Kubernetes_live
  }
;;

let customer_env : Sol_cli_deployment_plan.env_config =
  { name = "production"
  ; mode = Sol_cli_deployment_plan.Customer_cloud
  ; registry = "123456789.dkr.ecr.us-east-1.amazonaws.com"
  ; image_tag = "abc123"
  ; env = Some "prod"
  ; region = Some "us-east-1"
  ; base_domain = Some "example.com"
  ; cluster_issuer = "letsencrypt-prod"
  ; secret_backend = Sol_cli_manifest.Kubernetes_placeholder
  }
;;

let make_plan ?(env = customer_env) services : Sol_cli_deployment_plan.t =
  { workspace = "myapp"
  ; environment = env
  ; services
  ; topics = []
  ; migrations = []
  ; schema_subjects = []
  ; consumer_groups = []
  ; release_id = release_id_of_test
  ; requested_scope = "workspace"
  ; profile = None
  }
;;

let test_up_request_uses_explicit_tag () =
  let r =
    Sol_cli_command_request.make_up_request
      ~scope:None
      ~dry_run:false
      ~tag:(Some "v1.2.3")
      ~confirm_group_change:false
      ~keep_releases:20
      ~git_sha:(fun () ->
        Alcotest.fail "git_sha should not be called when tag is explicit")
  in
  match r with
  | Ok req -> Alcotest.(check string) "explicit tag" "v1.2.3" req.image_tag
  | Error msg -> Alcotest.fail msg
;;

let test_up_request_falls_back_to_git_sha () =
  let r =
    Sol_cli_command_request.make_up_request
      ~scope:None
      ~dry_run:false
      ~tag:None
      ~confirm_group_change:false
      ~keep_releases:20
      ~git_sha:(fun () -> Ok "sha-deadbeef")
  in
  match r with
  | Ok req -> Alcotest.(check string) "git sha fallback" "sha-deadbeef" req.image_tag
  | Error msg -> Alcotest.fail msg
;;

let git_unavailable () = Error "fatal: not a git repository"

let test_up_request_warns_on_fallback_tag () =
  match
    Sol_cli_command_request.make_up_request
      ~scope:None
      ~dry_run:false
      ~tag:None
      ~confirm_group_change:false
      ~keep_releases:20
      ~git_sha:git_unavailable
  with
  | Error msg -> Alcotest.fail msg
  | Ok req ->
    Alcotest.(check string) "fallback tag" "dev" req.image_tag;
    (match req.image_tag_warning with
     | None -> Alcotest.fail "expected a warning for the fallback tag"
     | Some w ->
       Alcotest.(check bool)
         ("names git's reason: " ^ w)
         true
         (Sol_cli_string.contains ~needle:"not a git repository" w);
       Alcotest.(check bool)
         ("names --image-tag: " ^ w)
         true
         (Sol_cli_string.contains ~needle:"--image-tag" w))
;;

let test_up_request_resolved_sha_has_no_warning () =
  match
    Sol_cli_command_request.make_up_request
      ~scope:None
      ~dry_run:false
      ~tag:None
      ~confirm_group_change:false
      ~keep_releases:20
      ~git_sha:(fun () -> Ok "abc1234")
  with
  | Error msg -> Alcotest.fail msg
  | Ok req -> Alcotest.(check (option string)) "no warning" None req.image_tag_warning
;;

let deploy_without_tag ~git_sha =
  Sol_cli_command_request.make_deploy_request
    ~target:"prod/aws/us-east-1"
    ~scope:None
    ~dry_run:false
    ~emit_to:None
    ~emit_plan_to:None
    ~image_tag:None
    ~image_refs:[]
    ~registry:None
    ~secret_backend:None
    ~confirm_group_change:false
    ~loki_push_url:None
    ~keep_releases:20
    ~await_delegation:None
    ~git_sha
;;

let test_deploy_request_refuses_unresolvable_sha () =
  match deploy_without_tag ~git_sha:git_unavailable with
  | Ok req -> Alcotest.fail ("deploy tagged images " ^ req.image_tag)
  | Error msg ->
    Alcotest.(check bool)
      ("names --image-tag: " ^ msg)
      true
      (Sol_cli_string.contains ~needle:"--image-tag" msg);
    Alcotest.(check bool)
      ("names git's reason: " ^ msg)
      true
      (Sol_cli_string.contains ~needle:"not a git repository" msg)
;;

let test_deploy_request_tags_with_resolved_sha () =
  match deploy_without_tag ~git_sha:(fun () -> Ok "abc1234") with
  | Error msg -> Alcotest.fail msg
  | Ok req -> Alcotest.(check string) "sha tag" "abc1234" req.image_tag
;;

let test_up_request_preserves_mode () =
  let r =
    Sol_cli_command_request.make_up_request
      ~scope:None
      ~dry_run:true
      ~tag:(Some "t")
      ~confirm_group_change:false
      ~keep_releases:20
      ~git_sha:(fun () -> Ok "")
  in
  match r with
  | Ok req ->
    Alcotest.(check bool)
      "dry-run mode"
      true
      (match req.mode with
       | Sol_cli_command_request.Dry_run -> true
       | Apply -> false)
  | Error msg -> Alcotest.fail msg
;;

let test_deploy_request_uses_explicit_tag () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~scope:None
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "sha-abc")
      ~image_refs:[]
      ~registry:(Some "reg.example.com")
      ~secret_backend:(Some Sol_cli_manifest.Kubernetes_placeholder)
      ~confirm_group_change:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Alcotest.fail "git_sha should not be called")
  in
  match r with
  | Ok req -> Alcotest.(check string) "explicit tag" "sha-abc" req.image_tag
  | Error msg -> Alcotest.fail msg
;;

let test_deploy_request_local_mode_builds_request () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~scope:None
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "v2")
      ~image_refs:[]
      ~registry:(Some "gcr.io/myproject")
      ~secret_backend:(Some Sol_cli_manifest.Kubernetes_placeholder)
      ~confirm_group_change:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  match r with
  | Ok req ->
    Alcotest.(check bool)
      "deploy apply"
      true
      (match req.action with
       | Sol_cli_command_request.Deploy_apply -> true
       | Deploy_dry_run _ | Deploy_emit_to _ -> false)
  | Error msg -> Alcotest.fail msg
;;

let test_deploy_request_gitops_action () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~scope:None
      ~dry_run:false
      ~emit_to:(Some "/tmp/gitops")
      ~emit_plan_to:None
      ~image_tag:(Some "tag")
      ~image_refs:[]
      ~registry:(Some "reg")
      ~secret_backend:(Some Sol_cli_manifest.Kubernetes_placeholder)
      ~confirm_group_change:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  match r with
  | Ok req ->
    Alcotest.(check bool)
      "gitops action"
      true
      (match req.action with
       | Sol_cli_command_request.Deploy_emit_to "/tmp/gitops" -> true
       | Deploy_apply | Deploy_dry_run _ | Deploy_emit_to _ -> false)
  | Error msg -> Alcotest.fail msg
;;

let test_deploy_request_dry_run_action_preserves_emit_to () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~scope:None
      ~dry_run:true
      ~emit_to:(Some "/tmp/gitops")
      ~emit_plan_to:None
      ~image_tag:(Some "tag")
      ~image_refs:[]
      ~registry:(Some "reg")
      ~secret_backend:(Some Sol_cli_manifest.Kubernetes_placeholder)
      ~confirm_group_change:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  match r with
  | Ok req ->
    Alcotest.(check bool)
      "dry-run action preserves emit_to"
      true
      (match req.action with
       | Sol_cli_command_request.Deploy_dry_run { emit_to = Some "/tmp/gitops" } -> true
       | Deploy_apply | Deploy_emit_to _ | Deploy_dry_run _ -> false)
  | Error msg -> Alcotest.fail msg
;;

let test_deploy_request_rejects_empty_target () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:""
      ~scope:None
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "tag")
      ~image_refs:[]
      ~registry:(Some "reg")
      ~secret_backend:(Some Sol_cli_manifest.Kubernetes_placeholder)
      ~confirm_group_change:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  Alcotest.(check bool) "empty target rejected" true (Result.is_error r)
;;

let test_deploy_request_registry_omitted_stays_none () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~scope:None
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "tag")
      ~image_refs:[]
      ~registry:None
      ~secret_backend:(Some Sol_cli_manifest.Kubernetes_placeholder)
      ~confirm_group_change:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  match r with
  | Ok req -> Alcotest.(check (option string)) "registry stays None" None req.registry
  | Error msg -> Alcotest.fail msg
;;

let test_deploy_request_accepts_image_refs () =
  let digest = "reg.example.com/ws/svc@sha256:" ^ String.make 64 'a' in
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~scope:None
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "unused")
      ~image_refs:[ Some "svc", digest ]
      ~registry:(Some "reg")
      ~secret_backend:(Some Sol_cli_manifest.Kubernetes_placeholder)
      ~confirm_group_change:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  match r with
  | Ok req -> Alcotest.(check int) "one reference carried" 1 (List.length req.image_refs)
  | Error msg -> Alcotest.fail msg
;;

let test_deploy_request_rejects_mutable_image_ref () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~scope:None
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "unused")
      ~image_refs:[ None, "reg.example.com/ws/svc:latest" ]
      ~registry:(Some "reg")
      ~secret_backend:(Some Sol_cli_manifest.Kubernetes_placeholder)
      ~confirm_group_change:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  Alcotest.(check bool) "mutable reference rejected" true (Result.is_error r)
;;

let test_plan_local_mode_fields () =
  let plan = make_plan ~env:local_env [ svc_spec ] in
  Alcotest.(check string) "workspace" "myapp" plan.workspace;
  Alcotest.(check bool)
    "mode Local"
    true
    (plan.environment.Sol_cli_deployment_plan.mode = Sol_cli_deployment_plan.Local);
  Alcotest.(check string)
    "registry"
    "sol-registry:5000"
    plan.environment.Sol_cli_deployment_plan.registry
;;

let test_plan_customer_cloud_mode_fields () =
  let plan = make_plan ~env:customer_env [ svc_spec ] in
  Alcotest.(check bool)
    "mode Customer_cloud"
    true
    (plan.environment.Sol_cli_deployment_plan.mode
     = Sol_cli_deployment_plan.Customer_cloud);
  Alcotest.(check string)
    "ECR registry"
    "123456789.dkr.ecr.us-east-1.amazonaws.com"
    plan.environment.Sol_cli_deployment_plan.registry
;;

let test_plan_service_count () =
  let plan = make_plan [ svc_spec; worker_spec; fn_spec ] in
  Alcotest.(check int) "three services" 3 (List.length plan.services)
;;

let test_plan_service_primitives () =
  let plan = make_plan [ svc_spec; worker_spec; fn_spec ] in
  let primitives =
    plan.services |> List.map (fun s -> s.Sol_cli_deployment_plan.primitive)
  in
  Alcotest.(check bool)
    "Svc present"
    true
    (List.mem Sol_cli_deployment_plan.Svc primitives);
  Alcotest.(check bool)
    "Worker present"
    true
    (List.mem Sol_cli_deployment_plan.Worker primitives);
  Alcotest.(check bool) "Fn present" true (List.mem Sol_cli_deployment_plan.Fn primitives)
;;

let test_plan_consumer_groups_derived_from_workers () =
  let resolved_config : Sol_cli_config.t =
    { project = Some "myapp"
    ; target = Result.get_ok (Sol_cli_config.parse_target "prod/aws/us-east-1")
    ; resources =
        [ { name = "events"
          ; typ = Some "kafka"
          ; partition_key = None
          ; sort_key = None
          ; indexes = []
          ; size = None
          ; omit = false
          }
        ]
    ; services =
        [ { name = "notify_worker"
          ; typ = None
          ; path = None
          ; uses = [ "events" ]
          ; scale_min = None
          ; scale_max = None
          ; language = None
          ; omit = false
          }
        ]
    }
  in
  let plan =
    { (make_plan [ svc_spec; worker_spec ]) with
      consumer_groups =
        Sol_cli_deployment_plan.derive_consumer_groups
          ~declared:(Sol_cli_config.declared_of_config resolved_config)
          "myapp"
          (make_plan [ svc_spec; worker_spec ]).Sol_cli_deployment_plan.services
    }
  in
  Alcotest.(check int)
    "one consumer group for one worker"
    1
    (List.length plan.consumer_groups);
  Alcotest.(check (list string))
    "group name"
    [ "myapp.comms.notify_worker" ]
    (List.map Sol_cli_plan_ids.Consumer_group.to_string plan.consumer_groups)
;;

let test_plan_svc_does_not_produce_consumer_group () =
  let groups = Sol_cli_deployment_plan.derive_consumer_groups "myapp" [ svc_spec ] in
  Alcotest.(check int) "Svc yields no consumer groups" 0 (List.length groups)
;;

let render_ok spec =
  match
    Sol_cli_deployment_render.render_spec
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder
      spec
  with
  | Ok (ns_yaml, workload_yaml) -> ns_yaml, workload_yaml
  | Error e -> Alcotest.fail ("render_spec failed: " ^ e)
;;

let run_plan_ok ~mode ?secret_backend plan =
  match
    Sol_cli_executor.run_plan
      (Sol_cli_execution.context
         ~cluster:Sol_cli_kube_destination.local_context
         ~workspace:plan.Sol_cli_deployment_plan.workspace
         ())
      ~mode
      ?secret_backend
      plan
  with
  | Ok rs -> rs
  | Error e -> Alcotest.fail ("run_plan failed: " ^ e)
;;

let test_render_svc_produces_deployment_and_service () =
  let _, workload_yaml = render_ok svc_spec in
  assert_contains "svc workload has Deployment" workload_yaml "kind: Deployment";
  assert_contains "svc workload has Service" workload_yaml "kind: Service"
;;

let test_render_worker_has_deployment_no_service () =
  let _, workload_yaml = render_ok worker_spec in
  assert_contains "worker has Deployment" workload_yaml "kind: Deployment";
  assert_absent "worker no Service" workload_yaml "kind: Service\n"
;;

let test_render_fn_produces_cronjob () =
  let _, workload_yaml = render_ok fn_spec in
  assert_contains "fn has CronJob" workload_yaml "kind: CronJob";
  assert_absent "fn no Deployment" workload_yaml "kind: Deployment"
;;

let test_render_namespace_yaml_is_non_empty () =
  let ns_yaml, _ = render_ok svc_spec in
  Alcotest.(check bool) "namespace_yaml non-empty" true (String.length ns_yaml > 0)
;;

let test_render_artifact_count_matches_services () =
  let plan = make_plan [ svc_spec; worker_spec; fn_spec ] in
  let results = run_plan_ok ~mode:Sol_cli_executor.Dry_run plan in
  Alcotest.(check int) "one result per service" 3 (List.length results)
;;

let test_render_artifact_image_matches_spec () =
  let plan = make_plan [ svc_spec ] in
  let results = run_plan_ok ~mode:Sol_cli_executor.Dry_run plan in
  let r = List.hd results in
  Alcotest.(check string)
    "artifact image"
    "registry.example.com/myapp/charge-svc:abc123"
    r.image
;;

let test_render_no_docker_or_k8s_calls () =
  let plan = make_plan [ svc_spec; worker_spec; fn_spec ] in
  let results = run_plan_ok ~mode:Sol_cli_executor.Dry_run plan in
  Alcotest.(check bool) "renders without side effects" true (List.length results = 3)
;;

let with_temp_dir f =
  let dir = Filename.temp_file "sol-phases-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    (fun () -> f dir)
    ~finally:(fun () ->
      (try
         Sys.readdir dir
         |> Array.iter (fun name ->
           try Sys.remove (Filename.concat dir name) with
           | _ -> ())
       with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
;;

let test_gitops_emit_creates_file () =
  with_temp_dir (fun dir ->
    let plan = make_plan [ svc_spec ] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
    Alcotest.(check bool) "gitops file created" true (Sys.file_exists path))
;;

let test_gitops_emit_file_contains_yaml_separator () =
  with_temp_dir (fun dir ->
    let plan = make_plan [ svc_spec ] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
    let content =
      let ic = open_in path in
      let s = In_channel.input_all ic in
      close_in ic;
      s
    in
    assert_contains "yaml separator present" content "---")
;;

let test_gitops_emit_file_has_namespace_kind () =
  with_temp_dir (fun dir ->
    let plan = make_plan [ svc_spec ] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
    let content =
      let ic = open_in path in
      let s = In_channel.input_all ic in
      close_in ic;
      s
    in
    assert_contains "Namespace kind present" content "kind: Namespace";
    assert_contains "namespace name present" content "name: myapp-payments")
;;

let test_gitops_emit_uses_placeholder_backend () =
  with_temp_dir (fun dir ->
    let env =
      { customer_env with secret_backend = Sol_cli_manifest.Kubernetes_placeholder }
    in
    let plan = make_plan ~env [ svc_spec ] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
    let content =
      let ic = open_in path in
      let s = In_channel.input_all ic in
      close_in ic;
      s
    in
    assert_contains
      "placeholder comment present"
      content
      "Populate these values before applying")
;;

let test_gitops_emit_one_file_per_service () =
  with_temp_dir (fun dir ->
    let plan = make_plan [ svc_spec; worker_spec ] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let files = Sys.readdir dir |> Array.to_list in
    Alcotest.(check int) "two service files + two release files" 4 (List.length files);
    let record =
      Sol_cli_release.(
        configmap_name (of_plan ~apply_mode:Sol_cli_release.Gitops plan) ^ ".yaml")
    in
    Alcotest.(check bool) "release record emitted" true (List.mem record files);
    Alcotest.(check bool)
      "current-release pointer emitted"
      true
      (List.mem "sol-current-release.yaml" files))
;;

let test_gitops_release_artifact_is_deterministic () =
  with_temp_dir (fun dir_a ->
    with_temp_dir (fun dir_b ->
      let plan = make_plan [ svc_spec; worker_spec ] in
      ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir_a) plan);
      ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir_b) plan);
      let record =
        Sol_cli_release.configmap_name
          (Sol_cli_release.of_plan ~apply_mode:Sol_cli_release.Gitops plan)
        ^ ".yaml"
      in
      let read dir name =
        let ic = open_in (Filename.concat dir name) in
        let s = In_channel.input_all ic in
        close_in ic;
        s
      in
      Alcotest.(check string)
        "record bytes identical"
        (read dir_a record)
        (read dir_b record);
      Alcotest.(check string)
        "pointer bytes identical"
        (read dir_a "sol-current-release.yaml")
        (read dir_b "sol-current-release.yaml")))
;;

let test_local_executor_result_fields () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      svc_spec
    |> ok
  in
  Alcotest.(check string) "local namespace" "myapp-payments" r.namespace;
  Alcotest.(check string) "local name" "charge-svc" r.name;
  Alcotest.(check string)
    "local image"
    "registry.example.com/myapp/charge-svc:abc123"
    r.image
;;

let test_direct_executor_result_fields () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      svc_spec
    |> ok
  in
  Alcotest.(check string) "direct namespace" "myapp-payments" r.namespace;
  Alcotest.(check string) "direct name" "charge-svc" r.name;
  Alcotest.(check string)
    "direct image"
    "registry.example.com/myapp/charge-svc:abc123"
    r.image
;;

let test_gitops_executor_result_fields () =
  with_temp_dir (fun dir ->
    let r =
      Sol_cli_executor.gitops
        ~ctx:Sol_cli_kube_destination.local_context
        ~workspace:"myapp"
        ~release_id:release_id_of_test
        ~dir
        svc_spec
      |> ok
    in
    Alcotest.(check string) "gitops namespace" "myapp-payments" r.namespace;
    Alcotest.(check string) "gitops name" "charge-svc" r.name;
    Alcotest.(check string)
      "gitops image"
      "registry.example.com/myapp/charge-svc:abc123"
      r.image)
;;

let test_local_worker_executor_result_fields () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      worker_spec
    |> ok
  in
  Alcotest.(check string) "local worker namespace" "myapp-comms" r.namespace;
  Alcotest.(check string) "local worker name" "notify-worker" r.name
;;

let test_direct_fn_executor_result_fields () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      fn_spec
    |> ok
  in
  Alcotest.(check string) "direct fn namespace" "myapp-billing" r.namespace;
  Alcotest.(check string) "direct fn name" "invoice-fn" r.name
;;

let test_state_dry_run_is_noop () =
  Alcotest.(check bool)
    "no-op outcome is Ok"
    true
    (Result.is_ok
       (Sol_cli_deployment_state.record_outcome
          ~ctx:Sol_cli_kube_destination.local_context
          "myapp"
          Sol_cli_deployment_state.Dry_run))
;;

let test_state_failed_is_noop () =
  Alcotest.(check bool)
    "no-op outcome is Ok"
    true
    (Result.is_ok
       (Sol_cli_deployment_state.record_outcome
          ~ctx:Sol_cli_kube_destination.local_context
          "myapp"
          (Sol_cli_deployment_state.Failed { phase = "render"; message = "YAML error" })))
;;

let test_state_emitted_is_noop () =
  Alcotest.(check bool)
    "no-op outcome is Ok"
    true
    (Result.is_ok
       (Sol_cli_deployment_state.record_outcome
          ~ctx:Sol_cli_kube_destination.local_context
          "myapp"
          (Sol_cli_deployment_state.Emitted
             { file = "/tmp/myapp-payments-charge-svc.yaml" })))
;;

let test_state_removed_consumer_groups () =
  let prev = [ "myapp.comms.notify_worker"; "myapp.billing.invoice_fn" ] in
  let next = [ "myapp.comms.notify_worker" ] in
  let removed = Sol_cli_deployment_state.removed_consumer_groups ~prev ~next in
  Alcotest.(check (list string))
    "invoice_fn worker removed"
    [ "myapp.billing.invoice_fn" ]
    removed
;;

let test_state_no_removal_when_stable () =
  let groups = [ "myapp.comms.notify_worker" ] in
  let removed =
    Sol_cli_deployment_state.removed_consumer_groups ~prev:groups ~next:groups
  in
  Alcotest.(check (list string)) "stable plan: no removals" [] removed
;;

let test_local_and_direct_share_plan_type () =
  let plan = make_plan ~env:local_env [ svc_spec ] in
  let local_results =
    List.map
      (Sol_cli_executor.local
         ~ctx:Sol_cli_kube_destination.local_context
         ~workspace:plan.workspace
         ~release_id:plan.release_id
         ~dry_run:true)
      plan.services
    |> List.map ok
  in
  let direct_results =
    List.map
      (Sol_cli_executor.local
         ~ctx:Sol_cli_kube_destination.local_context
         ~workspace:plan.workspace
         ~release_id:plan.release_id
         ~dry_run:true)
      plan.services
    |> List.map ok
  in
  Alcotest.(check int)
    "same result count"
    (List.length local_results)
    (List.length direct_results);
  let lr = List.hd local_results
  and dr = List.hd direct_results in
  Alcotest.(check string) "local namespace = direct namespace" lr.namespace dr.namespace;
  Alcotest.(check string) "local name = direct name" lr.name dr.name;
  Alcotest.(check string) "local image = direct image" lr.image dr.image
;;

let test_gitops_shares_plan_type () =
  with_temp_dir (fun dir ->
    let plan = make_plan ~env:customer_env [ svc_spec ] in
    let gitops_results =
      List.map
        (Sol_cli_executor.gitops
           ~ctx:Sol_cli_kube_destination.local_context
           ~workspace:plan.workspace
           ~release_id:plan.release_id
           ~dir)
        plan.services
      |> List.map ok
    in
    let direct_results =
      List.map
        (Sol_cli_executor.local
           ~ctx:Sol_cli_kube_destination.local_context
           ~workspace:plan.workspace
           ~release_id:plan.release_id
           ~dry_run:true)
        plan.services
      |> List.map ok
    in
    let gr = List.hd gitops_results
    and dr = List.hd direct_results in
    Alcotest.(check string)
      "gitops namespace = direct namespace"
      gr.namespace
      dr.namespace;
    Alcotest.(check string) "gitops name = direct name" gr.name dr.name;
    Alcotest.(check string) "gitops image = direct image" gr.image dr.image)
;;

let test_change_set_build_is_path_agnostic () =
  with_temp_dir (fun dir ->
    let plan = make_plan [ svc_spec ] in
    let id r =
      r.Sol_cli_executor.namespace, r.Sol_cli_executor.name, r.Sol_cli_executor.image
    in
    let id_dry = id (List.hd (run_plan_ok ~mode:Sol_cli_executor.Dry_run plan)) in
    let id_emit = id (List.hd (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan)) in
    Alcotest.(check bool) "dry vs emit: identity identical" true (id_dry = id_emit))
;;

let test_all_paths_start_from_same_plan_workspace () =
  let plan_local = make_plan ~env:local_env [ svc_spec ] in
  let plan_direct = make_plan ~env:customer_env [ svc_spec ] in
  let plan_gitops =
    make_plan
      ~env:{ customer_env with secret_backend = Sol_cli_manifest.Kubernetes_placeholder }
      [ svc_spec ]
  in
  let plan_hosted =
    make_plan
      ~env:{ customer_env with mode = Sol_cli_deployment_plan.Sol_hosted }
      [ svc_spec ]
  in
  List.iter
    (fun plan ->
       Alcotest.(check string)
         "workspace consistent"
         "myapp"
         plan.Sol_cli_deployment_plan.workspace;
       Alcotest.(check int) "service count consistent" 1 (List.length plan.services))
    [ plan_local; plan_direct; plan_gitops; plan_hosted ]
;;

let test_up_execution_descriptor_uses_host_push_image () =
  let exec =
    Sol_cli_up_execution.service_execution
      ~workspace:"myapp"
      ~ctx_dir:"/tmp/myapp"
      ~sha:"abc123"
      svc_spec
  in
  Alcotest.(check string) "k8s name" "charge-svc" exec.k8s_name;
  Alcotest.(check string) "namespace" "myapp-payments" exec.namespace;
  Alcotest.(check string) "Docker context is the workspace" "/tmp/myapp" exec.context;
  Alcotest.(check string)
    "push image"
    "localhost:5000/myapp/charge-svc:abc123"
    exec.push_image;
  Alcotest.(check string)
    "dockerfile"
    "/tmp/myapp/app/payments/charge_svc/Dockerfile"
    exec.dockerfile
;;

let test_up_request_rejects_nonpositive_keep () =
  let r =
    Sol_cli_command_request.make_up_request
      ~scope:None
      ~dry_run:false
      ~tag:(Some "t")
      ~confirm_group_change:false
      ~keep_releases:0
      ~git_sha:(fun () -> Ok "")
  in
  Alcotest.(check bool) "zero keep rejected" true (Result.is_error r)
;;

let test_deploy_request_rejects_nonpositive_keep () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~scope:None
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "tag")
      ~image_refs:[]
      ~registry:(Some "reg")
      ~secret_backend:(Some Sol_cli_manifest.Kubernetes_placeholder)
      ~confirm_group_change:false
      ~loki_push_url:None
      ~keep_releases:0
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  Alcotest.(check bool) "zero keep rejected" true (Result.is_error r)
;;

let%test "request_validation: up: explicit tag used" =
  test_up_request_uses_explicit_tag ()
;;

let%test "request_validation: up: git sha fallback" =
  test_up_request_falls_back_to_git_sha ()
;;

let%test "request_validation: up: mode preserved" = test_up_request_preserves_mode ()

let%test "request_validation: up: unresolvable sha warns (BUG-058)" =
  test_up_request_warns_on_fallback_tag ()
;;

let%test "request_validation: up: resolved sha, no warning" =
  test_up_request_resolved_sha_has_no_warning ()
;;

let%test "request_validation: deploy: unresolvable sha refused (BUG-058)" =
  test_deploy_request_refuses_unresolvable_sha ()
;;

let%test "request_validation: deploy: resolved sha tags images" =
  test_deploy_request_tags_with_resolved_sha ()
;;

let%test "request_validation: deploy: explicit tag used" =
  test_deploy_request_uses_explicit_tag ()
;;

let%test "request_validation: deploy: local mode Ok" =
  test_deploy_request_local_mode_builds_request ()
;;

let%test "request_validation: deploy: gitops action" =
  test_deploy_request_gitops_action ()
;;

let%test "request_validation: deploy: dry-run action preserves emit_to" =
  test_deploy_request_dry_run_action_preserves_emit_to ()
;;

let%test "request_validation: deploy: empty target rejected" =
  test_deploy_request_rejects_empty_target ()
;;

let%test "request_validation: deploy: registry omitted stays None" =
  test_deploy_request_registry_omitted_stays_none ()
;;

let%test "request_validation: deploy: image refs carried" =
  test_deploy_request_accepts_image_refs ()
;;

let%test "request_validation: deploy: mutable image ref rejected" =
  test_deploy_request_rejects_mutable_image_ref ()
;;

let%test "request_validation: up: non-positive keep-releases rejected" =
  test_up_request_rejects_nonpositive_keep ()
;;

let%test "request_validation: deploy: non-positive keep-releases rejected" =
  test_deploy_request_rejects_nonpositive_keep ()
;;

let%test "plan_construction: local mode fields" = test_plan_local_mode_fields ()

let%test "plan_construction: customer_cloud mode fields" =
  test_plan_customer_cloud_mode_fields ()
;;

let%test "plan_construction: service count preserved" = test_plan_service_count ()
let%test "plan_construction: all three primitives" = test_plan_service_primitives ()

let%test "plan_construction: consumer groups from workers" =
  test_plan_consumer_groups_derived_from_workers ()
;;

let%test "plan_construction: Svc yields no consumer group" =
  test_plan_svc_does_not_produce_consumer_group ()
;;

let%test "render_artifacts: svc: Deployment + Service" =
  test_render_svc_produces_deployment_and_service ()
;;

let%test "render_artifacts: worker: Deployment, no Service" =
  test_render_worker_has_deployment_no_service ()
;;

let%test "render_artifacts: fn: CronJob, no Deployment" =
  test_render_fn_produces_cronjob ()
;;

let%test "render_artifacts: namespace yaml non-empty" =
  test_render_namespace_yaml_is_non_empty ()
;;

let%test "render_artifacts: one artifact per service" =
  test_render_artifact_count_matches_services ()
;;

let%test "render_artifacts: artifact image from spec" =
  test_render_artifact_image_matches_spec ()
;;

let%test "render_artifacts: build is side-effect-free" =
  test_render_no_docker_or_k8s_calls ()
;;

let%test "gitops_emit: file created" = test_gitops_emit_creates_file ()

let%test "gitops_emit: file contains YAML separator" =
  test_gitops_emit_file_contains_yaml_separator ()
;;

let%test "gitops_emit: file has Namespace kind" =
  test_gitops_emit_file_has_namespace_kind ()
;;

let%test "gitops_emit: uses placeholder backend" =
  test_gitops_emit_uses_placeholder_backend ()
;;

let%test "gitops_emit: one file per service + release artifact" =
  test_gitops_emit_one_file_per_service ()
;;

let%test "gitops_emit: release artifact deterministic" =
  test_gitops_release_artifact_is_deterministic ()
;;

let%test "executor_commands: local: svc result fields" =
  test_local_executor_result_fields ()
;;

let%test "executor_commands: direct: svc result fields" =
  test_direct_executor_result_fields ()
;;

let%test "executor_commands: gitops: svc result fields" =
  test_gitops_executor_result_fields ()
;;

let%test "executor_commands: local: worker result fields" =
  test_local_worker_executor_result_fields ()
;;

let%test "executor_commands: direct: fn result fields" =
  test_direct_fn_executor_result_fields ()
;;

let%test "state_update: Dry_run is no-op" = test_state_dry_run_is_noop ()
let%test "state_update: Failed is no-op" = test_state_failed_is_noop ()
let%test "state_update: Emitted is no-op" = test_state_emitted_is_noop ()
let%test "state_update: removed consumer groups" = test_state_removed_consumer_groups ()
let%test "state_update: stable plan: no removals" = test_state_no_removal_when_stable ()

let%test "path_consistency: local and direct share plan type" =
  test_local_and_direct_share_plan_type ()
;;

let%test "path_consistency: gitops shares plan type" = test_gitops_shares_plan_type ()

let%test "path_consistency: build is mode-agnostic" =
  test_change_set_build_is_path_agnostic ()
;;

let%test "path_consistency: all paths start from same workspace" =
  test_all_paths_start_from_same_plan_workspace ()
;;

let%test "path_consistency: up execution descriptor uses host push image" =
  test_up_execution_descriptor_uses_host_push_image ()
;;
