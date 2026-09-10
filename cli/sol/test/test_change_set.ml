(* Tests for Sol_cli_executor.run_plan (formerly Sol_cli_change_set).
   Verifies that run_plan renders all specs and dispatches correctly per mode. *)

(* ── fixtures ────────────────────────────────────────────────────────────── *)

let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err ->
      Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)

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

let svc_spec : Sol_cli_deployment_plan.service_spec =
  {
    domain = "payments";
    source_name = "charge_svc";
    k8s_name = k8s_name "charge-svc";
    namespace = namespace ~workspace:"myapp" ~domain:"payments";
    primitive = Sol_cli_deployment_plan.Svc;
    source_dir = "app/payments/charge_svc";
    image = "registry.example.com/myapp/charge-svc:abc123";
    config = [];
    secrets = [];
    volumes = [];
    schedule = None;
    replicas = 1;
    cpu = cpu "100m";
    memory = memory "128Mi";
    rollout_strategy = None;
    ingress_host = None;
    ingress_path = None;
    extra_labels = [];
    progressive_delivery = None;
  }

let worker_spec : Sol_cli_deployment_plan.service_spec =
  {
    domain = "comms";
    source_name = "notify_worker";
    k8s_name = k8s_name "notify-worker";
    namespace = namespace ~workspace:"myapp" ~domain:"comms";
    primitive = Sol_cli_deployment_plan.Worker;
    source_dir = "app/comms/notify_worker";
    image = "registry.example.com/myapp/notify-worker:abc123";
    config = [];
    secrets = [];
    volumes = [];
    schedule = None;
    replicas = 1;
    cpu = cpu "100m";
    memory = memory "128Mi";
    rollout_strategy = None;
    ingress_host = None;
    ingress_path = None;
    extra_labels = [];
    progressive_delivery = None;
  }

let env_config : Sol_cli_deployment_plan.env_config =
  {
    name = "myapp";
    mode = Sol_cli_deployment_plan.Customer_cloud;
    registry = "registry.example.com";
    image_tag = "abc123";
    env = None;
    region = None;
    base_domain = None;
    secret_backend = Sol_cli_manifest.Kubernetes_placeholder;
  }

let make_plan services =
  {
    Sol_cli_deployment_plan.workspace = "myapp";
    environment = env_config;
    services;
    topics = [];
    migrations = [];
    schema_subjects = [];
    consumer_groups = [];
  }

let run_ok ~mode ?secret_backend plan =
  match
    Sol_cli_executor.run_plan ~workspace:plan.Sol_cli_deployment_plan.workspace
      ~mode ?secret_backend plan.Sol_cli_deployment_plan.services
  with
  | Ok rs -> rs
  | Error e -> Alcotest.fail ("run_plan unexpectedly failed: " ^ e)

(* ── dry-run ─────────────────────────────────────────────────────────────── *)

let test_dry_run_result_count () =
  let plan = make_plan [ svc_spec; worker_spec ] in
  let results = run_ok ~mode:Sol_cli_executor.Dry_run plan in
  Alcotest.(check int) "result count" 2 (List.length results)

let test_dry_run_result_fields () =
  let plan = make_plan [ svc_spec ] in
  let results = run_ok ~mode:Sol_cli_executor.Dry_run plan in
  let r = List.hd results in
  Alcotest.(check string)
    "namespace" "myapp-payments" r.Sol_cli_executor.namespace;
  Alcotest.(check string) "name" "charge-svc" r.Sol_cli_executor.name

let test_dry_run_worker () =
  let plan = make_plan [ worker_spec ] in
  let results = run_ok ~mode:Sol_cli_executor.Dry_run plan in
  let r = List.hd results in
  Alcotest.(check string)
    "worker namespace" "myapp-comms" r.Sol_cli_executor.namespace;
  Alcotest.(check string) "worker name" "notify-worker" r.Sol_cli_executor.name

(* ── emit-to ─────────────────────────────────────────────────────────────── *)

let test_emit_to_writes_file () =
  let dir = Filename.temp_file "sol-cs-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let plan = make_plan [ svc_spec ] in
  let _results = run_ok ~mode:(Sol_cli_executor.Emit_to dir) plan in
  let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
  let exists = Sys.file_exists path in
  (try Sys.remove path with _ -> ());
  (try Unix.rmdir dir with _ -> ());
  Alcotest.(check bool) "emit_to file created" true exists

let test_emit_to_result_fields () =
  let dir = Filename.temp_file "sol-cs-emit-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let plan = make_plan [ worker_spec ] in
  let results = run_ok ~mode:(Sol_cli_executor.Emit_to dir) plan in
  let path = Filename.concat dir "myapp-comms-notify-worker.yaml" in
  (try Sys.remove path with _ -> ());
  (try Unix.rmdir dir with _ -> ());
  Alcotest.(check int) "result count" 1 (List.length results);
  let r = List.hd results in
  Alcotest.(check string) "namespace" "myapp-comms" r.Sol_cli_executor.namespace;
  Alcotest.(check string) "name" "notify-worker" r.Sol_cli_executor.name

(* ── entry point ──────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "run_plan"
    [
      ( "dry_run",
        [
          Alcotest.test_case "result count" `Quick test_dry_run_result_count;
          Alcotest.test_case "result fields (svc)" `Quick
            test_dry_run_result_fields;
          Alcotest.test_case "result fields (worker)" `Quick test_dry_run_worker;
        ] );
      ( "emit_to",
        [
          Alcotest.test_case "file written" `Quick test_emit_to_writes_file;
          Alcotest.test_case "result fields" `Quick test_emit_to_result_fields;
        ] );
    ]
