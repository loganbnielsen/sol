let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let namespace ~domain =
  match Sol_cli_deployment_plan.namespace_result ~workspace:"myapp" ~domain with
  | Ok namespace -> namespace
  | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let quantity parse s =
  match parse s with
  | Ok q -> q
  | Error message -> Alcotest.fail message
;;

let spec ~domain ~name ~k8s primitive : Sol_cli_deployment_plan.service_spec =
  { domain
  ; source_name = name
  ; k8s_name = k8s_name k8s
  ; namespace = namespace ~domain
  ; primitive
  ; source_dir = "app/" ^ domain ^ "/" ^ name
  ; image = "registry.example.com/myapp/" ^ k8s ^ ":abc123"
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
  ; cpu = quantity Sol_cli_toml.cpu_quantity_of_string "100m"
  ; memory = quantity Sol_cli_toml.memory_quantity_of_string "128Mi"
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

let release_id =
  Sol_cli_release_id.of_content
    { workspace = "myapp"; environment = None; workloads = [] }
;;

let plan ?profile services : Sol_cli_deployment_plan.t =
  { workspace = "myapp"
  ; environment =
      { name = "myapp"
      ; mode = Sol_cli_deployment_plan.Customer_cloud
      ; registry = "registry.example.com"
      ; image_tag = "abc123"
      ; env = None
      ; region = None
      ; base_domain = None
      ; cluster_issuer = "letsencrypt-prod"
      ; secret_backend = Sol_cli_manifest.Kubernetes_placeholder
      }
  ; services
  ; topics = []
  ; migrations = []
  ; schema_subjects = []
  ; consumer_groups = []
  ; release_id
  ; requested_scope = "workspace"
  ; profile
  }
;;

let production : Sol_cli_deployment_plan.profile_claim =
  { profile = Sol_cli_profile.Production_single_region
  ; requirements = []
  ; application_findings = []
  }
;;

let temp_dir () =
  let dir = Filename.temp_file "sol-deploy-run-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir
;;

let with_context ?(migrations = []) f =
  let root = temp_dir () in
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir root;
       Out_channel.with_open_text "sol.yml" (fun oc ->
         output_string oc "project: myapp\n");
       Targets_fixture.write ~target:"dev/aws/us-east-1" "target:\n  cluster_name: c\n";
       if migrations <> []
       then (
         Unix.mkdir "db" 0o755;
         Unix.mkdir "db/migrations" 0o755;
         List.iter
           (fun name ->
              Out_channel.with_open_text (Filename.concat "db/migrations" name) (fun oc ->
                output_string oc "select 1;\n"))
           migrations);
       let config =
         match Sol_cli_config.load_for_target ~target:"dev/aws/us-east-1" with
         | Ok config -> config
         | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
       in
       let facts =
         match Sol_cli_workspace_model.load ~root with
         | Ok facts -> facts
         | Error e -> Alcotest.fail e
       in
       let ctx : Sol_cli_deploy_run.context =
         { execution =
             Sol_cli_execution.context
               ~cluster:Sol_cli_kube_destination.local_context
               ~workspace:"myapp"
               ()
         ; sha = "abc123"
         ; registry = "registry.example.com"
         ; facts
         ; secret_backend = Sol_cli_manifest.Kubernetes_placeholder
         ; emit_plan_to = None
         ; target_cfg = config.target
         ; resolved_config = config
         ; services = []
         ; inventory = []
         ; image_refs = []
         ; requested_scope = "workspace"
         ; target_name = "dev/aws/us-east-1"
         ; run_log = Sol_cli_run_log.create ~base:(temp_dir ()) ~prefix:"deploy" ()
         ; keep_releases = 5
         }
       in
       f ctx)
;;

let gate ctx ~plan ~live =
  Sol_cli_report.collect (fun () ->
    Sol_cli_deploy_run.migration_prerequisite ctx ~plan ~live)
;;

let reported = List.map snd

let test_no_profile_is_not_checked () =
  with_context ~migrations:[ "001_init.sql" ] (fun ctx ->
    match gate ctx ~plan:(plan []) ~live:true with
    | Ok (), [] -> ()
    | Ok (), lines ->
      Alcotest.failf "unexpected report: %s" (String.concat "; " (reported lines))
    | Error _, _ -> Alcotest.fail "a deploy with no profile must not be gated")
;;

let test_offline_run_reports_not_verified () =
  with_context ~migrations:[ "001_init.sql" ] (fun ctx ->
    match gate ctx ~plan:(plan ~profile:production []) ~live:false with
    | Ok (), [ (_, line) ] ->
      Alcotest.(check bool)
        "says NOT verified"
        true
        (Sol_cli_string.contains ~needle:"NOT verified" line)
    | Ok (), lines ->
      Alcotest.failf "expected one report, got: %s" (String.concat "; " (reported lines))
    | Error _, _ -> Alcotest.fail "an offline run must not fail the gate")
;;

let test_offline_run_without_migrations_says_nothing () =
  with_context (fun ctx ->
    match gate ctx ~plan:(plan ~profile:production []) ~live:false with
    | Ok (), [] -> ()
    | _ -> Alcotest.fail "no migrations: nothing to verify and nothing to say")
;;

let test_deploy_events_one_per_service () =
  with_context (fun ctx ->
    let deployment_id = Sol_cli_deployment_id.create ~now:0. ~entropy:"test" in
    let events =
      Sol_cli_deploy_run.deploy_events
        ~workspace:"myapp"
        ~target_cfg:ctx.target_cfg
        ~deployment_id
        (plan
           [ spec ~domain:"payments" ~name:"charge_svc" ~k8s:"charge-svc" Svc
           ; spec ~domain:"comms" ~name:"notify_worker" ~k8s:"notify-worker" Worker
           ])
    in
    Alcotest.(check (list (pair string string)))
      "service and primitive"
      [ "charge-svc", "svc"; "notify-worker", "worker" ]
      (List.map (fun (e : Sol_cli_deploy_event.t) -> e.service, e.primitive) events);
    Alcotest.(check bool)
      "joined to the deployment"
      true
      (List.for_all
         (fun (e : Sol_cli_deploy_event.t) -> e.deployment_id = deployment_id)
         events);
    Alcotest.(check (list string))
      "the target's env"
      [ "dev"; "dev" ]
      (List.map (fun (e : Sol_cli_deploy_event.t) -> e.env) events))
;;

let () =
  Alcotest.run
    "deploy run"
    [ ( "migration gate (AUDIT-069)"
      , [ Alcotest.test_case "no profile" `Quick test_no_profile_is_not_checked
        ; Alcotest.test_case
            "offline: not verified"
            `Quick
            test_offline_run_reports_not_verified
        ; Alcotest.test_case
            "offline: no migrations"
            `Quick
            test_offline_run_without_migrations_says_nothing
        ] )
    ; ( "deploy events (FEAT-071)"
      , [ Alcotest.test_case "one per service" `Quick test_deploy_events_one_per_service ]
      )
    ]
;;
