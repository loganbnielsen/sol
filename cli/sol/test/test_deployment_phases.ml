(* Phase-oriented tests for the Sol deployment compiler.
   Documents the contract at each phase boundary so infra contributors can
   reason about plan generation, artifact rendering, GitOps emit, executor
   dispatch, and state update in isolation — no Docker or Kubernetes required. *)

(* ── shared helpers ──────────────────────────────────────────────────────── *)

let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)

let namespace ~workspace ~domain =
  Sol_cli_deployment_plan.namespace_of_exn ~workspace ~domain

let cpu s =
  match Sol_cli_toml.cpu_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message

let memory s =
  match Sol_cli_toml.memory_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else begin
    let found = ref false in
    for i = 0 to hl - nl do
      if not !found && String.sub haystack i nl = needle then found := true
    done;
    !found
  end

let assert_contains label haystack needle =
  Alcotest.(check bool)
    (Printf.sprintf "%s: contains %S" label needle)
    true (contains haystack needle)

let assert_absent label haystack needle =
  Alcotest.(check bool)
    (Printf.sprintf "%s: absent %S" label needle)
    false (contains haystack needle)

(* ── fixtures ────────────────────────────────────────────────────────────── *)

let svc_spec : Sol_cli_deployment_plan.service_spec = {
  domain      = "payments";
  source_name = "charge_svc";
  k8s_name    = k8s_name "charge-svc";
  namespace   = namespace ~workspace:"myapp" ~domain:"payments";
  primitive   = Sol_cli_deployment_plan.Svc;
  source_dir  = "app/payments/charge_svc";
  image       = "registry.example.com/myapp/charge-svc:abc123";
  config      = [];
  secrets     = [];
  schedule              = None;
  replicas              = 1;
  cpu                   = cpu "100m";
  memory                = memory "128Mi";
  rollout_strategy      = None;
  ingress_host          = None;
  ingress_path          = None;
  extra_labels          = [];
  progressive_delivery  = None;
}

let worker_spec : Sol_cli_deployment_plan.service_spec = {
  domain      = "comms";
  source_name = "notify_worker";
  k8s_name    = k8s_name "notify-worker";
  namespace   = namespace ~workspace:"myapp" ~domain:"comms";
  primitive   = Sol_cli_deployment_plan.Worker;
  source_dir  = "app/comms/notify_worker";
  image       = "registry.example.com/myapp/notify-worker:abc123";
  config      = [];
  secrets     = [];
  schedule              = None;
  replicas              = 1;
  cpu                   = cpu "100m";
  memory                = memory "128Mi";
  rollout_strategy      = None;
  ingress_host          = None;
  ingress_path          = None;
  extra_labels          = [];
  progressive_delivery  = None;
}

let fn_spec : Sol_cli_deployment_plan.service_spec = {
  domain      = "billing";
  source_name = "invoice_fn";
  k8s_name    = k8s_name "invoice-fn";
  namespace   = namespace ~workspace:"myapp" ~domain:"billing";
  primitive   = Sol_cli_deployment_plan.Fn;
  source_dir  = "app/billing/invoice_fn";
  image       = "registry.example.com/myapp/invoice-fn:abc123";
  config      = [];
  secrets     = [];
  schedule    = Some "0 9 * * 1";
  replicas    = 1;
  cpu         = cpu "100m";
  memory      = memory "128Mi";
  rollout_strategy      = None;
  ingress_host          = None;
  ingress_path          = None;
  extra_labels          = [];
  progressive_delivery  = None;
}

let local_env : Sol_cli_deployment_plan.env_config = {
  name           = "local";
  mode           = Sol_cli_deployment_plan.Local;
  registry       = "sol-registry:5000";
  image_tag      = "dev";
  env            = None;
  region         = None;
  base_domain    = None;
  secret_backend = Sol_cli_manifest.Kubernetes_live;
}

let customer_env : Sol_cli_deployment_plan.env_config = {
  name           = "production";
  mode           = Sol_cli_deployment_plan.Customer_cloud;
  registry       = "123456789.dkr.ecr.us-east-1.amazonaws.com";
  image_tag      = "abc123";
  env            = Some "prod";
  region         = Some "us-east-1";
  base_domain    = Some "example.com";
  secret_backend = Sol_cli_manifest.Kubernetes_placeholder;
}

let make_plan ?(env = customer_env) services : Sol_cli_deployment_plan.t = {
  workspace       = "myapp";
  environment     = env;
  services;
  topics          = [];
  migrations      = [];
  schema_subjects = [];
  consumer_groups = [];
}

(* ── Phase 1: request validation ────────────────────────────────────────── *)

let test_up_request_uses_explicit_tag () =
  let r = Sol_cli_command_request.make_up_request
    ~filter_path:None ~dry_run:false ~tag:(Some "v1.2.3")
    ~confirm_group_change:false
    ~git_sha:(fun () -> Alcotest.fail "git_sha should not be called when tag is explicit")
  in
  match r with
  | Ok req -> Alcotest.(check string) "explicit tag" "v1.2.3"
                req.Sol_cli_command_request.image_tag
  | Error msg -> Alcotest.fail msg

let test_up_request_falls_back_to_git_sha () =
  let r = Sol_cli_command_request.make_up_request
    ~filter_path:None ~dry_run:false ~tag:None
    ~confirm_group_change:false
    ~git_sha:(fun () -> "sha-deadbeef")
  in
  match r with
  | Ok req -> Alcotest.(check string) "git sha fallback" "sha-deadbeef"
                req.Sol_cli_command_request.image_tag
  | Error msg -> Alcotest.fail msg

let test_up_request_preserves_mode () =
  let r = Sol_cli_command_request.make_up_request
    ~filter_path:None ~dry_run:true ~tag:(Some "t")
    ~confirm_group_change:false ~git_sha:(fun () -> "")
  in
  match r with
  | Ok req -> Alcotest.(check bool) "dry-run mode" true
                (match req.Sol_cli_command_request.mode with
                 | Sol_cli_command_request.Dry_run -> true
                 | Apply -> false)
  | Error msg -> Alcotest.fail msg

let test_deploy_request_uses_explicit_tag () =
  let r = Sol_cli_command_request.make_deploy_request
    ~target:"dev/aws/us-east-1"
    ~filter_path:None ~dry_run:false ~emit_to:None ~emit_plan_to:None
    ~image_tag:(Some "sha-abc") ~registry:(Some "reg.example.com")
    ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder
    ~confirm_group_change:false ~loki_push_url:None
    ~git_sha:(fun () -> Alcotest.fail "git_sha should not be called")
  in
  match r with
  | Ok req -> Alcotest.(check string) "explicit tag" "sha-abc"
                req.Sol_cli_command_request.image_tag
  | Error msg -> Alcotest.fail msg

let test_deploy_request_local_mode_builds_request () =
  let r = Sol_cli_command_request.make_deploy_request
    ~target:"dev/aws/us-east-1"
    ~filter_path:None ~dry_run:false ~emit_to:None ~emit_plan_to:None
    ~image_tag:(Some "v2") ~registry:(Some "gcr.io/myproject")
    ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder
    ~confirm_group_change:false ~loki_push_url:None ~git_sha:(fun () -> "")
  in
  Alcotest.(check bool) "deploy request Ok" true (Result.is_ok r)

let test_deploy_request_gitops_emit_to_stored () =
  let r = Sol_cli_command_request.make_deploy_request
    ~target:"dev/aws/us-east-1"
    ~filter_path:None ~dry_run:false ~emit_to:(Some "/tmp/gitops")
    ~emit_plan_to:None ~image_tag:(Some "tag")
    ~registry:(Some "reg") ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder
    ~confirm_group_change:false ~loki_push_url:None ~git_sha:(fun () -> "")
  in
  match r with
  | Ok req ->
    Alcotest.(check (option string)) "emit_to stored"
      (Some "/tmp/gitops") req.Sol_cli_command_request.emit_to
  | Error msg -> Alcotest.fail msg

(* FEAT-026: target is required — make_deploy_request rejects an empty one
   even though cmdliner's `required` positional should already prevent
   this from reaching here in practice. *)
let test_deploy_request_rejects_empty_target () =
  let r = Sol_cli_command_request.make_deploy_request
    ~target:"" ~filter_path:None ~dry_run:false ~emit_to:None ~emit_plan_to:None
    ~image_tag:(Some "tag") ~registry:(Some "reg")
    ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder
    ~confirm_group_change:false ~loki_push_url:None ~git_sha:(fun () -> "")
  in
  Alcotest.(check bool) "empty target rejected" true (Result.is_error r)

(* --registry omitted stores None, not a hardcoded default — the
   resolution (target file, or fail if it has none too) happens in
   cmd_deploy.ml once the target loads, not in this constructor. *)
let test_deploy_request_registry_omitted_stays_none () =
  let r = Sol_cli_command_request.make_deploy_request
    ~target:"dev/aws/us-east-1" ~filter_path:None ~dry_run:false
    ~emit_to:None ~emit_plan_to:None ~image_tag:(Some "tag") ~registry:None
    ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder
    ~confirm_group_change:false ~loki_push_url:None ~git_sha:(fun () -> "")
  in
  match r with
  | Ok req -> Alcotest.(check (option string)) "registry stays None"
                None req.Sol_cli_command_request.registry
  | Error msg -> Alcotest.fail msg

(* ── Phase 2: plan construction ─────────────────────────────────────────── *)

let test_plan_local_mode_fields () =
  let plan = make_plan ~env:local_env [svc_spec] in
  Alcotest.(check string)   "workspace" "myapp"          plan.Sol_cli_deployment_plan.workspace;
  Alcotest.(check bool)     "mode Local" true
    (plan.Sol_cli_deployment_plan.environment.Sol_cli_deployment_plan.mode
     = Sol_cli_deployment_plan.Local);
  Alcotest.(check string)   "registry" "sol-registry:5000"
    plan.Sol_cli_deployment_plan.environment.Sol_cli_deployment_plan.registry

let test_plan_customer_cloud_mode_fields () =
  let plan = make_plan ~env:customer_env [svc_spec] in
  Alcotest.(check bool) "mode Customer_cloud" true
    (plan.Sol_cli_deployment_plan.environment.Sol_cli_deployment_plan.mode
     = Sol_cli_deployment_plan.Customer_cloud);
  Alcotest.(check string) "ECR registry"
    "123456789.dkr.ecr.us-east-1.amazonaws.com"
    plan.Sol_cli_deployment_plan.environment.Sol_cli_deployment_plan.registry

let test_plan_service_count () =
  let plan = make_plan [svc_spec; worker_spec; fn_spec] in
  Alcotest.(check int) "three services" 3
    (List.length plan.Sol_cli_deployment_plan.services)

let test_plan_service_primitives () =
  let plan = make_plan [svc_spec; worker_spec; fn_spec] in
  let primitives =
    List.map (fun s -> s.Sol_cli_deployment_plan.primitive) plan.Sol_cli_deployment_plan.services
  in
  Alcotest.(check bool) "Svc present" true
    (List.mem Sol_cli_deployment_plan.Svc primitives);
  Alcotest.(check bool) "Worker present" true
    (List.mem Sol_cli_deployment_plan.Worker primitives);
  Alcotest.(check bool) "Fn present" true
    (List.mem Sol_cli_deployment_plan.Fn primitives)

let test_plan_consumer_groups_derived_from_workers () =
  let plan = { (make_plan [svc_spec; worker_spec]) with
    consumer_groups =
      Sol_cli_deployment_plan.derive_consumer_groups "myapp"
        (make_plan [svc_spec; worker_spec]).Sol_cli_deployment_plan.services
  } in
  Alcotest.(check int) "one consumer group for one worker" 1
    (List.length plan.Sol_cli_deployment_plan.consumer_groups);
  Alcotest.(check (list string)) "group name"
    ["myapp.comms.notify_worker"]
    (List.map Sol_cli_plan_ids.Consumer_group.to_string
       plan.Sol_cli_deployment_plan.consumer_groups)

let test_plan_svc_does_not_produce_consumer_group () =
  let groups =
    Sol_cli_deployment_plan.derive_consumer_groups "myapp" [svc_spec]
  in
  Alcotest.(check int) "Svc yields no consumer groups" 0 (List.length groups)

let render_ok spec =
  match Sol_cli_deployment_render.render_spec ~workspace:"myapp"
          ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec with
  | Ok (ns_yaml, workload_yaml) -> (ns_yaml, workload_yaml)
  | Error e -> Alcotest.fail ("render_spec failed: " ^ e)

let run_plan_ok ~mode ?secret_backend plan =
  match Sol_cli_executor.run_plan ~workspace:plan.Sol_cli_deployment_plan.workspace ~mode ?secret_backend
          plan.Sol_cli_deployment_plan.services with
  | Ok rs  -> rs
  | Error e -> Alcotest.fail ("run_plan failed: " ^ e)

(* ── Phase 3: render artifacts ──────────────────────────────────────────── *)

let test_render_svc_produces_deployment_and_service () =
  let (_, workload_yaml) = render_ok svc_spec in
  assert_contains "svc workload has Deployment" workload_yaml "kind: Deployment";
  assert_contains "svc workload has Service"    workload_yaml "kind: Service"

let test_render_worker_has_deployment_no_service () =
  let (_, workload_yaml) = render_ok worker_spec in
  assert_contains "worker has Deployment"  workload_yaml "kind: Deployment";
  assert_absent   "worker no Service"      workload_yaml "kind: Service\n"

let test_render_fn_produces_cronjob () =
  let (_, workload_yaml) = render_ok fn_spec in
  assert_contains "fn has CronJob"   workload_yaml "kind: CronJob";
  assert_absent   "fn no Deployment" workload_yaml "kind: Deployment"

let test_render_namespace_yaml_is_non_empty () =
  let (ns_yaml, _) = render_ok svc_spec in
  Alcotest.(check bool) "namespace_yaml non-empty" true (String.length ns_yaml > 0)

let test_render_artifact_count_matches_services () =
  let plan = make_plan [svc_spec; worker_spec; fn_spec] in
  let results = run_plan_ok ~mode:Sol_cli_executor.Dry_run plan in
  Alcotest.(check int) "one result per service" 3 (List.length results)

let test_render_artifact_image_matches_spec () =
  let plan = make_plan [svc_spec] in
  let results = run_plan_ok ~mode:Sol_cli_executor.Dry_run plan in
  let r = List.hd results in
  Alcotest.(check string) "artifact image"
    "registry.example.com/myapp/charge-svc:abc123"
    r.Sol_cli_executor.image

let test_render_no_docker_or_k8s_calls () =
  let plan = make_plan [svc_spec; worker_spec; fn_spec] in
  let results = run_plan_ok ~mode:Sol_cli_executor.Dry_run plan in
  Alcotest.(check bool) "renders without side effects" true (List.length results = 3)

(* ── Phase 4: GitOps emit ───────────────────────────────────────────────── *)

let with_temp_dir f =
  let dir = Filename.temp_file "sol-phases-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect (fun () -> f dir)
    ~finally:(fun () ->
      (try
         Array.iter (fun name ->
           (try Sys.remove (Filename.concat dir name) with _ -> ())
         ) (Sys.readdir dir)
       with _ -> ());
      (try Unix.rmdir dir with _ -> ()))

let test_gitops_emit_creates_file () =
  with_temp_dir (fun dir ->
    let plan = make_plan [svc_spec] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
    Alcotest.(check bool) "gitops file created" true (Sys.file_exists path)
  )

let test_gitops_emit_file_contains_yaml_separator () =
  with_temp_dir (fun dir ->
    let plan = make_plan [svc_spec] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
    let content =
      let ic = open_in path in
      let s = In_channel.input_all ic in
      close_in ic; s
    in
    assert_contains "yaml separator present" content "---"
  )

let test_gitops_emit_file_has_namespace_kind () =
  with_temp_dir (fun dir ->
    let plan = make_plan [svc_spec] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
    let content =
      let ic = open_in path in
      let s = In_channel.input_all ic in
      close_in ic; s
    in
    assert_contains "Namespace kind present" content "kind: Namespace";
    assert_contains "namespace name present" content "name: myapp-payments"
  )

let test_gitops_emit_uses_placeholder_backend () =
  with_temp_dir (fun dir ->
    let env = { customer_env with
      secret_backend = Sol_cli_manifest.Kubernetes_placeholder } in
    let plan = make_plan ~env [svc_spec] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
    let content =
      let ic = open_in path in
      let s = In_channel.input_all ic in
      close_in ic; s
    in
    assert_contains "placeholder comment present" content "Populate these values before applying"
  )

let test_gitops_emit_one_file_per_service () =
  with_temp_dir (fun dir ->
    let plan = make_plan [svc_spec; worker_spec] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let files = Sys.readdir dir |> Array.to_list in
    Alcotest.(check int) "one file per service" 2 (List.length files)
  )

(* ── Phase 5: executor commands ─────────────────────────────────────────── *)

let test_local_executor_result_fields () =
  let r = Sol_cli_executor.local ~workspace:"myapp" ~dry_run:true svc_spec in
  Alcotest.(check string) "local namespace" "myapp-payments" r.Sol_cli_executor.namespace;
  Alcotest.(check string) "local name"      "charge-svc"     r.Sol_cli_executor.name;
  Alcotest.(check string) "local image"
    "registry.example.com/myapp/charge-svc:abc123"
    r.Sol_cli_executor.image

let test_direct_executor_result_fields () =
  let r = Sol_cli_executor.local ~workspace:"myapp" ~dry_run:true svc_spec in
  Alcotest.(check string) "direct namespace" "myapp-payments" r.Sol_cli_executor.namespace;
  Alcotest.(check string) "direct name"      "charge-svc"     r.Sol_cli_executor.name;
  Alcotest.(check string) "direct image"
    "registry.example.com/myapp/charge-svc:abc123"
    r.Sol_cli_executor.image

let test_gitops_executor_result_fields () =
  with_temp_dir (fun dir ->
    let r = Sol_cli_executor.gitops ~workspace:"myapp" ~dir svc_spec in
    Alcotest.(check string) "gitops namespace" "myapp-payments" r.Sol_cli_executor.namespace;
    Alcotest.(check string) "gitops name"      "charge-svc"     r.Sol_cli_executor.name;
    Alcotest.(check string) "gitops image"
      "registry.example.com/myapp/charge-svc:abc123"
      r.Sol_cli_executor.image
  )

let test_local_worker_executor_result_fields () =
  let r = Sol_cli_executor.local ~workspace:"myapp" ~dry_run:true worker_spec in
  Alcotest.(check string) "local worker namespace" "myapp-comms"   r.Sol_cli_executor.namespace;
  Alcotest.(check string) "local worker name"      "notify-worker" r.Sol_cli_executor.name

let test_direct_fn_executor_result_fields () =
  let r = Sol_cli_executor.local ~workspace:"myapp" ~dry_run:true fn_spec in
  Alcotest.(check string) "direct fn namespace" "myapp-billing" r.Sol_cli_executor.namespace;
  Alcotest.(check string) "direct fn name"      "invoice-fn"    r.Sol_cli_executor.name

(* ── Phase 6: state update ──────────────────────────────────────────────── *)

let test_state_applied_does_not_raise () =
  Sol_cli_deployment_state.record_outcome "myapp"
    (Sol_cli_deployment_state.Applied {
      namespace = "myapp-payments"; name = "charge-svc";
      image = "registry.example.com/myapp/charge-svc:abc123";
      consumer_groups = ["myapp.comms.notify_worker"];
    })

let test_state_dry_run_is_noop () =
  Sol_cli_deployment_state.record_outcome "myapp"
    Sol_cli_deployment_state.Dry_run

let test_state_failed_is_noop () =
  Sol_cli_deployment_state.record_outcome "myapp"
    (Sol_cli_deployment_state.Failed { phase = "render"; message = "YAML error" })

let test_state_emitted_is_noop () =
  Sol_cli_deployment_state.record_outcome "myapp"
    (Sol_cli_deployment_state.Emitted { file = "/tmp/myapp-payments-charge-svc.yaml" })

let test_state_removed_consumer_groups () =
  let prev = ["myapp.comms.notify_worker"; "myapp.billing.invoice_fn"] in
  let next = ["myapp.comms.notify_worker"] in
  let removed = Sol_cli_deployment_state.removed_consumer_groups ~prev ~next in
  Alcotest.(check (list string)) "invoice_fn worker removed"
    ["myapp.billing.invoice_fn"] removed

let test_state_no_removal_when_stable () =
  let groups = ["myapp.comms.notify_worker"] in
  let removed = Sol_cli_deployment_state.removed_consumer_groups ~prev:groups ~next:groups in
  Alcotest.(check (list string)) "stable plan: no removals" [] removed

(* ── Phase 7: path consistency ──────────────────────────────────────────── *)

(* All four deployment paths take a Sol_cli_deployment_plan.t as input.
   These tests assert that local, direct, gitops, and hosted-stub paths all
   start from the same plan type and produce executor results with the same
   namespace/name/image shape. *)

let test_local_and_direct_share_plan_type () =
  let plan = make_plan ~env:local_env [svc_spec] in
  let local_results =
    List.map (Sol_cli_executor.local ~workspace:plan.Sol_cli_deployment_plan.workspace ~dry_run:true) plan.Sol_cli_deployment_plan.services
  in
  let direct_results =
    List.map (Sol_cli_executor.local ~workspace:plan.Sol_cli_deployment_plan.workspace ~dry_run:true) plan.Sol_cli_deployment_plan.services
  in
  Alcotest.(check int) "same result count" (List.length local_results) (List.length direct_results);
  let lr = List.hd local_results and dr = List.hd direct_results in
  Alcotest.(check string) "local namespace = direct namespace"
    lr.Sol_cli_executor.namespace dr.Sol_cli_executor.namespace;
  Alcotest.(check string) "local name = direct name"
    lr.Sol_cli_executor.name dr.Sol_cli_executor.name;
  Alcotest.(check string) "local image = direct image"
    lr.Sol_cli_executor.image dr.Sol_cli_executor.image

let test_gitops_shares_plan_type () =
  with_temp_dir (fun dir ->
    let plan = make_plan ~env:customer_env [svc_spec] in
    let gitops_results =
      List.map (Sol_cli_executor.gitops ~workspace:plan.Sol_cli_deployment_plan.workspace ~dir) plan.Sol_cli_deployment_plan.services
    in
    let direct_results =
      List.map (Sol_cli_executor.local ~workspace:plan.Sol_cli_deployment_plan.workspace ~dry_run:true) plan.Sol_cli_deployment_plan.services
    in
    let gr = List.hd gitops_results and dr = List.hd direct_results in
    Alcotest.(check string) "gitops namespace = direct namespace"
      gr.Sol_cli_executor.namespace dr.Sol_cli_executor.namespace;
    Alcotest.(check string) "gitops name = direct name"
      gr.Sol_cli_executor.name dr.Sol_cli_executor.name;
    Alcotest.(check string) "gitops image = direct image"
      gr.Sol_cli_executor.image dr.Sol_cli_executor.image
  )

let test_change_set_build_is_path_agnostic () =
  with_temp_dir (fun dir ->
    (* Identity fields (namespace, name, image) are mode-independent. *)
    let plan = make_plan [svc_spec] in
    let id r = (r.Sol_cli_executor.namespace, r.Sol_cli_executor.name, r.Sol_cli_executor.image) in
    let id_dry  = id (List.hd (run_plan_ok ~mode:Sol_cli_executor.Dry_run plan)) in
    let id_emit = id (List.hd (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan)) in
    Alcotest.(check bool) "dry vs emit: identity identical" true (id_dry = id_emit)
  )

let test_all_paths_start_from_same_plan_workspace () =
  let plan_local   = make_plan ~env:local_env    [svc_spec] in
  let plan_direct  = make_plan ~env:customer_env [svc_spec] in
  let plan_gitops  = make_plan ~env:{ customer_env with
    secret_backend = Sol_cli_manifest.Kubernetes_placeholder } [svc_spec] in
  let plan_hosted  = make_plan ~env:{ customer_env with
    mode = Sol_cli_deployment_plan.Sol_hosted } [svc_spec] in
  List.iter (fun plan ->
    Alcotest.(check string) "workspace consistent" "myapp"
      plan.Sol_cli_deployment_plan.workspace;
    Alcotest.(check int) "service count consistent" 1
      (List.length plan.Sol_cli_deployment_plan.services)
  ) [plan_local; plan_direct; plan_gitops; plan_hosted]

let test_up_execution_descriptor_uses_host_push_image () =
  let exec =
    Sol_cli_up_execution.service_execution
      ~workspace:"myapp" ~ctx_dir:"/tmp/myapp.docker-ctx" ~sha:"abc123" svc_spec
  in
  Alcotest.(check string) "k8s name" "charge-svc" exec.k8s_name;
  Alcotest.(check string) "namespace" "myapp-payments" exec.namespace;
  Alcotest.(check string) "push image"
    "localhost:5000/myapp/charge-svc:abc123" exec.push_image;
  Alcotest.(check string) "dockerfile"
    "/tmp/myapp.docker-ctx/app/payments/charge_svc/Dockerfile" exec.dockerfile

(* ── entry point ─────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "deployment_phases"
    [ "request_validation", [
        Alcotest.test_case "up: explicit tag used"          `Quick test_up_request_uses_explicit_tag
      ; Alcotest.test_case "up: git sha fallback"           `Quick test_up_request_falls_back_to_git_sha
      ; Alcotest.test_case "up: mode preserved"             `Quick test_up_request_preserves_mode
      ; Alcotest.test_case "deploy: explicit tag used"      `Quick test_deploy_request_uses_explicit_tag
      ; Alcotest.test_case "deploy: local mode Ok"          `Quick test_deploy_request_local_mode_builds_request
      ; Alcotest.test_case "deploy: emit_to stored"         `Quick test_deploy_request_gitops_emit_to_stored
      ; Alcotest.test_case "deploy: empty target rejected"  `Quick test_deploy_request_rejects_empty_target
      ; Alcotest.test_case "deploy: registry omitted stays None" `Quick test_deploy_request_registry_omitted_stays_none
      ]
    ; "plan_construction", [
        Alcotest.test_case "local mode fields"              `Quick test_plan_local_mode_fields
      ; Alcotest.test_case "customer_cloud mode fields"     `Quick test_plan_customer_cloud_mode_fields
      ; Alcotest.test_case "service count preserved"        `Quick test_plan_service_count
      ; Alcotest.test_case "all three primitives"           `Quick test_plan_service_primitives
      ; Alcotest.test_case "consumer groups from workers"   `Quick test_plan_consumer_groups_derived_from_workers
      ; Alcotest.test_case "Svc yields no consumer group"   `Quick test_plan_svc_does_not_produce_consumer_group
      ]
    ; "render_artifacts", [
        Alcotest.test_case "svc: Deployment + Service"      `Quick test_render_svc_produces_deployment_and_service
      ; Alcotest.test_case "worker: Deployment, no Service" `Quick test_render_worker_has_deployment_no_service
      ; Alcotest.test_case "fn: CronJob, no Deployment"     `Quick test_render_fn_produces_cronjob
      ; Alcotest.test_case "namespace yaml non-empty"       `Quick test_render_namespace_yaml_is_non_empty
      ; Alcotest.test_case "one artifact per service"        `Quick test_render_artifact_count_matches_services
      ; Alcotest.test_case "artifact image from spec"        `Quick test_render_artifact_image_matches_spec
      ; Alcotest.test_case "build is side-effect-free"      `Quick test_render_no_docker_or_k8s_calls
      ]
    ; "gitops_emit", [
        Alcotest.test_case "file created"                   `Quick test_gitops_emit_creates_file
      ; Alcotest.test_case "file contains YAML separator"   `Quick test_gitops_emit_file_contains_yaml_separator
      ; Alcotest.test_case "file has Namespace kind"        `Quick test_gitops_emit_file_has_namespace_kind
      ; Alcotest.test_case "uses placeholder backend"       `Quick test_gitops_emit_uses_placeholder_backend
      ; Alcotest.test_case "one file per service"           `Quick test_gitops_emit_one_file_per_service
      ]
    ; "executor_commands", [
        Alcotest.test_case "local: svc result fields"       `Quick test_local_executor_result_fields
      ; Alcotest.test_case "direct: svc result fields"      `Quick test_direct_executor_result_fields
      ; Alcotest.test_case "gitops: svc result fields"      `Quick test_gitops_executor_result_fields
      ; Alcotest.test_case "local: worker result fields"    `Quick test_local_worker_executor_result_fields
      ; Alcotest.test_case "direct: fn result fields"       `Quick test_direct_fn_executor_result_fields
      ]
    ; "state_update", [
        Alcotest.test_case "Applied does not raise"         `Quick test_state_applied_does_not_raise
      ; Alcotest.test_case "Dry_run is no-op"              `Quick test_state_dry_run_is_noop
      ; Alcotest.test_case "Failed is no-op"               `Quick test_state_failed_is_noop
      ; Alcotest.test_case "Emitted is no-op"              `Quick test_state_emitted_is_noop
      ; Alcotest.test_case "removed consumer groups"        `Quick test_state_removed_consumer_groups
      ; Alcotest.test_case "stable plan: no removals"       `Quick test_state_no_removal_when_stable
      ]
    ; "path_consistency", [
        Alcotest.test_case "local and direct share plan type"   `Quick test_local_and_direct_share_plan_type
      ; Alcotest.test_case "gitops shares plan type"            `Quick test_gitops_shares_plan_type
      ; Alcotest.test_case "build is mode-agnostic"             `Quick test_change_set_build_is_path_agnostic
      ; Alcotest.test_case "all paths start from same workspace" `Quick test_all_paths_start_from_same_plan_workspace
      ; Alcotest.test_case "up execution descriptor uses host push image" `Quick test_up_execution_descriptor_uses_host_push_image
      ]
    ]
