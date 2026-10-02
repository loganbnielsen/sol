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

let hostname s =
  match Sol_cli_toml.hostname_of_string s with
  | Ok host -> host
  | Error message -> Alcotest.fail message
;;

let ingress_path s =
  match Sol_cli_toml.ingress_path_of_string s with
  | Ok path -> path
  | Error message -> Alcotest.fail message
;;

let contains re s =
  try
    ignore (Str.search_forward re s 0);
    true
  with
  | Not_found -> false
;;

let gate_env : Sol_cli_deployment_plan.env_config =
  { name = "production"
  ; mode = Sol_cli_deployment_plan.Customer_cloud
  ; registry = "123.dkr.ecr.us-east-1.amazonaws.com"
  ; image_tag = "abc1234"
  ; env = Some "prod"
  ; region = Some "us-east-1"
  ; base_domain = Some "example.com"
  ; cluster_issuer = "letsencrypt-prod"
  ; secret_backend = Sol_cli_manifest.Kubernetes_placeholder
  }
;;

let ledger_namespace = namespace ~workspace:"myapp" ~domain:"payments"
let ledger_name = k8s_name "ledger-svc"
let billing_namespace = namespace ~workspace:"myapp" ~domain:"payments"
let billing_name = k8s_name "billing-svc"

let billing_call : Sol_cli_deployment_plan.service_call =
  { env_var = Sol_cli_kubernetes_name.call_env_var "ledger_svc"
  ; url =
      Sol_cli_kubernetes_name.service_url
        ~namespace:ledger_namespace
        ~k8s_name:ledger_name
  ; target_domain = "payments"
  ; target_name = ledger_name
  ; target_namespace = ledger_namespace
  }
;;

let billing_as_caller : Sol_cli_deployment_plan.service_call =
  { env_var = Sol_cli_kubernetes_name.call_env_var "billing_svc"
  ; url =
      Sol_cli_kubernetes_name.service_url
        ~namespace:billing_namespace
        ~k8s_name:billing_name
  ; target_domain = "payments"
  ; target_name = billing_name
  ; target_namespace = billing_namespace
  }
;;

let ledger_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "payments"
  ; source_name = "ledger_svc"
  ; k8s_name = ledger_name
  ; namespace = ledger_namespace
  ; primitive = Sol_cli_deployment_plan.Svc
  ; source_dir = ""
  ; image = "123.dkr.ecr.us-east-1.amazonaws.com/myapp/ledger-svc:abc1234"
  ; config = [ "LOG_LEVEL", "info" ]
  ; secrets = [ "DB_PASSWORD", "" ]
  ; volumes = []
  ; schedule = None
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; replicas = 2
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu = cpu "250m"
  ; memory = memory "256Mi"
  ; rollout_strategy = Some Sol_cli_toml.Recreate
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = []
  ; called_by = [ billing_as_caller ]
  ; extra_labels = [ "team", "payments" ]
  ; progressive_delivery = None
  }
;;

let billing_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "payments"
  ; source_name = "billing_svc"
  ; k8s_name = billing_name
  ; namespace = billing_namespace
  ; primitive = Sol_cli_deployment_plan.Svc
  ; source_dir = ""
  ; image = "123.dkr.ecr.us-east-1.amazonaws.com/myapp/billing-svc:abc1234"
  ; config = [ "LOG_LEVEL", "info" ]
  ; secrets = [ "STRIPE_KEY", "" ]
  ; volumes =
      [ { Sol_cli_toml.name = "cache"
        ; mount_path = "/var/cache"
        ; size = "1Gi"
        ; access_mode = Sol_cli_toml.ReadWriteOnce
        }
      ; { Sol_cli_toml.name = "shared"
        ; mount_path = "/var/shared"
        ; size = "5Gi"
        ; access_mode = Sol_cli_toml.ReadOnlyMany
        }
      ]
  ; schedule = None
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu = cpu "500m"
  ; memory = memory "512Mi"
  ; rollout_strategy = None
  ; ingress_host = Some (hostname "billing.example.com")
  ; ingress_path = Some (ingress_path "/api")
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = [ billing_call ]
  ; called_by = []
  ; extra_labels = [ "team", "payments" ]
  ; progressive_delivery =
      Some
        (Sol_cli_toml.Canary
           { steps =
               [ Sol_cli_toml.Weight 20
               ; Sol_cli_toml.Pause (Some 60)
               ; Sol_cli_toml.Weight 100
               ]
           })
  }
;;

let gate_services = [ billing_spec; ledger_spec ]

let gate_release_id =
  Sol_cli_release_id.of_content
    { workspace = "myapp"
    ; environment = gate_env.env
    ; workloads = List.map Sol_cli_deployment_plan.release_workload_of_spec gate_services
    }
;;

let gate_plan : Sol_cli_deployment_plan.t =
  { workspace = "myapp"
  ; release_id = gate_release_id
  ; environment = gate_env
  ; services = gate_services
  ; topics = []
  ; migrations = []
  ; schema_subjects = []
  ; consumer_groups = []
  ; requested_scope = "workspace"
  ; profile = None
  }
;;

let gate_release = Sol_cli_release.of_plan ~apply_mode:Sol_cli_release.Direct gate_plan

let reconstruct_ok () =
  match Sol_cli_rollback.service_specs_of_release gate_release with
  | Ok specs -> specs
  | Error msg -> Alcotest.failf "expected reconstruction to succeed: %s" msg
;;

let call_eq
      (c1 : Sol_cli_deployment_plan.service_call)
      (c2 : Sol_cli_deployment_plan.service_call)
  =
  c1.env_var = c2.env_var
  && c1.url = c2.url
  && c1.target_domain = c2.target_domain
  && Sol_cli_deployment_plan.k8s_name_to_string c1.target_name
     = Sol_cli_deployment_plan.k8s_name_to_string c2.target_name
  && Sol_cli_deployment_plan.namespace_to_string c1.target_namespace
     = Sol_cli_deployment_plan.namespace_to_string c2.target_namespace
;;

let calls_eq a b = List.length a = List.length b && List.for_all2 call_eq a b

let assert_spec_equal ~label (expected : Sol_cli_deployment_plan.service_spec) got =
  let k8s = Sol_cli_deployment_plan.k8s_name_to_string in
  let ns = Sol_cli_deployment_plan.namespace_to_string in
  let field name = Printf.sprintf "%s: %s" label name in
  Alcotest.(check string)
    (field "domain")
    expected.domain
    got.Sol_cli_deployment_plan.domain;
  Alcotest.(check string) (field "source_name") expected.source_name got.source_name;
  Alcotest.(check string) (field "k8s_name") (k8s expected.k8s_name) (k8s got.k8s_name);
  Alcotest.(check string) (field "namespace") (ns expected.namespace) (ns got.namespace);
  Alcotest.(check bool) (field "primitive") true (expected.primitive = got.primitive);
  Alcotest.(check string) (field "image") expected.image got.image;
  Alcotest.(check bool) (field "config") true (expected.config = got.config);
  Alcotest.(check bool) (field "secrets") true (expected.secrets = got.secrets);
  Alcotest.(check bool) (field "volumes") true (expected.volumes = got.volumes);
  Alcotest.(check bool) (field "schedule") true (expected.schedule = got.schedule);
  Alcotest.(check bool)
    (field "scheduled_concurrency")
    true
    (expected.scheduled_concurrency = got.scheduled_concurrency);
  Alcotest.(check int) (field "backoff_limit") expected.backoff_limit got.backoff_limit;
  Alcotest.(check int) (field "replicas") expected.replicas got.replicas;
  Alcotest.(check string)
    (field "cpu")
    (Sol_cli_toml.cpu_quantity_to_string expected.cpu)
    (Sol_cli_toml.cpu_quantity_to_string got.cpu);
  Alcotest.(check string)
    (field "memory")
    (Sol_cli_toml.memory_quantity_to_string expected.memory)
    (Sol_cli_toml.memory_quantity_to_string got.memory);
  Alcotest.(check bool)
    (field "rollout_strategy")
    true
    (expected.rollout_strategy = got.rollout_strategy);
  Alcotest.(check bool)
    (field "ingress_host")
    true
    (Option.map Sol_cli_toml.hostname_to_string expected.ingress_host
     = Option.map Sol_cli_toml.hostname_to_string got.ingress_host);
  Alcotest.(check bool)
    (field "ingress_path")
    true
    (Option.map Sol_cli_toml.ingress_path_to_string expected.ingress_path
     = Option.map Sol_cli_toml.ingress_path_to_string got.ingress_path);
  Alcotest.(check string)
    (field "cluster_issuer")
    expected.cluster_issuer
    got.cluster_issuer;
  Alcotest.(check bool) (field "calls") true (calls_eq expected.calls got.calls);
  Alcotest.(check bool)
    (field "called_by")
    true
    (calls_eq expected.called_by got.called_by);
  Alcotest.(check bool)
    (field "extra_labels")
    true
    (expected.extra_labels = got.extra_labels);
  Alcotest.(check bool)
    (field "progressive_delivery")
    true
    (expected.progressive_delivery = got.progressive_delivery)
;;

let test_gate_a_decode_correctness () =
  match reconstruct_ok () with
  | [ (got_billing, billing_by); (got_ledger, ledger_by) ] ->
    assert_spec_equal ~label:"billing_svc" billing_spec got_billing;
    assert_spec_equal ~label:"ledger_svc" ledger_spec got_ledger;
    Alcotest.(check string) "billing provenance" gate_release.release_id billing_by;
    Alcotest.(check string) "ledger provenance" gate_release.release_id ledger_by
  | specs -> Alcotest.failf "expected 2 reconstructed specs, got %d" (List.length specs)
;;

let test_gate_b_identity_correctness () =
  let specs = reconstruct_ok () in
  let reconstructed_id =
    Sol_cli_release.derived_release_id gate_release |> Sol_cli_release_id.to_string
  in
  Alcotest.(check string)
    "reconstructed release id matches the record"
    gate_release.release_id
    reconstructed_id;
  Alcotest.(check int)
    "every reconstructed workload carries observable provenance"
    (List.length specs)
    (List.length gate_release.workloads)
;;

let render_by_identity ~release_id apply_specs =
  List.map
    (fun ((s : Sol_cli_deployment_plan.service_spec), _) ->
       let key =
         ( Sol_cli_deployment_plan.namespace_to_string s.namespace
         , Sol_cli_deployment_plan.k8s_name_to_string s.k8s_name )
       in
       let rendered =
         match
           Sol_cli_deployment_render.render_spec
             ~workspace:gate_plan.workspace
             ?env:gate_plan.environment.env
             ~release_id
             ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder
             s
         with
         | Ok (ns_yaml, body) -> ns_yaml ^ body
         | Error msg -> Alcotest.fail msg
       in
       key, rendered)
    apply_specs
  |> List.sort (fun (a, _) (b, _) -> compare a b)
;;

let test_gate_c_render_correctness () =
  let specs = reconstruct_ok () in
  let release_id =
    match Sol_cli_release_id.of_string gate_release.release_id with
    | Ok id -> id
    | Error msg -> Alcotest.fail msg
  in
  let original =
    render_by_identity
      ~release_id
      (List.map (fun s -> s, gate_release.release_id) gate_plan.services)
  in
  let reconstructed = render_by_identity ~release_id specs in
  Alcotest.(check (list (pair string string)))
    "same object identity set"
    (List.map fst original)
    (List.map fst reconstructed);
  List.iter2
    (fun (key, original_bytes) (_, reconstructed_bytes) ->
       Alcotest.(check string)
         (Printf.sprintf "%s/%s canonical bytes" (fst key) (snd key))
         original_bytes
         reconstructed_bytes)
    original
    reconstructed
;;

let bad_workload_release update : Sol_cli_release.t =
  let record_id = "r-0000000000000000" in
  { release_id = record_id
  ; workspace = "myapp"
  ; environment = Some "prod"
  ; workloads =
      [ Sol_cli_release.applied_by
          record_id
          (update (Sol_cli_deployment_plan.release_workload_of_spec ledger_spec))
      ]
  ; migrations = []
  ; apply_mode = Sol_cli_release.Direct
  }
;;

let test_gate_failure_unknown_rollout_encoding () =
  let release = bad_workload_release (fun w -> { w with rollout = "canary:bogus" }) in
  match Sol_cli_rollback.service_specs_of_release release with
  | Ok _ -> Alcotest.fail "expected reconstruction to fail on an unknown rollout encoding"
  | Error msg ->
    assert (contains (Str.regexp "r-0000000000000000") msg);
    assert (contains (Str.regexp "ledger_svc") msg);
    assert (contains (Str.regexp (Str.quote "canary:bogus")) msg)
;;

let test_gate_failure_invalid_cpu () =
  let release = bad_workload_release (fun w -> { w with cpu = "not-a-cpu-quantity" }) in
  match Sol_cli_rollback.service_specs_of_release release with
  | Ok _ -> Alcotest.fail "expected reconstruction to fail on an invalid cpu quantity"
  | Error msg ->
    assert (contains (Str.regexp "ledger_svc") msg);
    assert (contains (Str.regexp (Str.quote "not-a-cpu-quantity")) msg)
;;

let with_migrations_dir files f =
  let dir = Filename.temp_file "sol-migrations-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (name, _) -> Sys.remove (Filename.concat dir name)) files;
      Unix.rmdir dir)
    (fun () ->
       files
       |> List.iter (fun (name, content) ->
         let oc = open_out (Filename.concat dir name) in
         output_string oc content;
         close_out oc);
       f dir)
;;

let migration_release ~migrations : Sol_cli_release.t =
  { release_id = "r-1111111111111111"
  ; workspace = "myapp"
  ; environment = None
  ; workloads = []
  ; migrations
  ; apply_mode = Sol_cli_release.Direct
  }
;;

let expand_sql = "-- sol:disposition expand\nALTER TABLE t ADD COLUMN c INT;"
let contract_sql = "-- sol:disposition contract\nALTER TABLE t DROP COLUMN c;"
let undeclared_sql = "ALTER TABLE t ADD COLUMN c INT;"

let test_migration_boundary_no_new_migrations_passes () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql" ]
           ~applied:(fun () -> Ok [ 1 ])
       with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_new_expand_passes () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql; "0002_add_col.sql", expand_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql"; "0002_add_col.sql" ]
           ~applied:(fun () -> Ok [ 1; 2 ])
       with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_new_contract_blocks () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql; "0002_drop_col.sql", contract_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql"; "0002_drop_col.sql" ]
           ~applied:(fun () -> Ok [ 1; 2 ])
       with
       | Ok () -> Alcotest.fail "expected a contracting migration to block the rollback"
       | Error (Sol_cli_rollback.Contracting_migration { release_id; migration }) ->
         Alcotest.(check string) "release_id" "r-1111111111111111" release_id;
         Alcotest.(check string) "migration" "0002_drop_col.sql" migration
       | Error e ->
         Alcotest.failf
           "expected Contracting_migration, got: %s"
           (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_undeclared_new_migration_blocks () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql; "0002_mystery.sql", undeclared_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql"; "0002_mystery.sql" ]
           ~applied:(fun () -> Ok [ 1; 2 ])
       with
       | Ok () ->
         Alcotest.fail "expected an undeclared disposition to block the rollback closed"
       | Error (Sol_cli_rollback.Undeclared_disposition { release_id; migration; reason })
         ->
         Alcotest.(check string) "release_id" "r-1111111111111111" release_id;
         Alcotest.(check string) "migration" "0002_mystery.sql" migration;
         assert (contains (Str.regexp "sol:disposition") reason)
       | Error e ->
         Alcotest.failf
           "expected Undeclared_disposition, got: %s"
           (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_ignores_already_recorded_contract () =
  with_migrations_dir
    [ "0001_drop_col.sql", contract_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_drop_col.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_drop_col.sql" ]
           ~applied:(fun () -> Ok [ 1 ])
       with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_applied_beyond_release_absent_locally_blocks () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql" ]
           ~applied:(fun () -> Ok [ 1; 2 ])
       with
       | Ok () ->
         Alcotest.fail
           "expected a migration applied to the target but absent from this checkout to \
            block the rollback"
       | Error (Sol_cli_rollback.Applied_migration_absent { release_id; version }) ->
         Alcotest.(check string) "release_id" "r-1111111111111111" release_id;
         Alcotest.(check int) "version" 2 version
       | Error e ->
         Alcotest.failf
           "expected Applied_migration_absent, got: %s"
           (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_applied_expansion_beyond_release_passes () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql; "0002_add_col.sql", expand_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql"; "0002_add_col.sql" ]
           ~applied:(fun () -> Ok [ 1; 2 ])
       with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_applied_state_unavailable_blocks () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql" ]
           ~applied:(fun () -> Error "migration-status Job cannot start")
       with
       | Ok () ->
         Alcotest.fail "expected an unreadable applied state to block the rollback"
       | Error (Sol_cli_rollback.Applied_state_unavailable { release_id; reason }) ->
         Alcotest.(check string) "release_id" "r-1111111111111111" release_id;
         assert (contains (Str.regexp "migration-status Job cannot start") reason)
       | Error e ->
         Alcotest.failf
           "expected Applied_state_unavailable, got: %s"
           (Sol_cli_rollback.migration_check_error_to_string e))
;;

let progressive_canary = Some (Sol_cli_toml.Canary { steps = [] })
let progressive_blue_green = Some Sol_cli_toml.Blue_green

let live_kind_cases =
  [ ( "svc, no progressive delivery"
    , Sol_cli_deployment_plan.Svc
    , None
    , Sol_cli_rollback.Live_deployment )
  ; ( "svc, canary"
    , Sol_cli_deployment_plan.Svc
    , progressive_canary
    , Sol_cli_rollback.Live_rollout )
  ; ( "svc, blue_green"
    , Sol_cli_deployment_plan.Svc
    , progressive_blue_green
    , Sol_cli_rollback.Live_rollout )
  ; ( "worker, no progressive delivery"
    , Sol_cli_deployment_plan.Worker
    , None
    , Sol_cli_rollback.Live_deployment )
  ; ( "worker, canary"
    , Sol_cli_deployment_plan.Worker
    , progressive_canary
    , Sol_cli_rollback.Live_rollout )
  ; ( "fn, no progressive delivery"
    , Sol_cli_deployment_plan.Fn
    , None
    , Sol_cli_rollback.Live_cronjob )
  ; ( "fn, canary (ignored)"
    , Sol_cli_deployment_plan.Fn
    , progressive_canary
    , Sol_cli_rollback.Live_cronjob )
  ]
;;

let test_live_kind_of_service_table () =
  live_kind_cases
  |> List.iter (fun (label, primitive, progressive_delivery, expected) ->
    let spec = { ledger_spec with primitive; progressive_delivery } in
    let got = Sol_cli_rollback.live_kind_of_service spec in
    Alcotest.(check bool) label true (got = expected))
;;

let live_kind_label = function
  | Sol_cli_rollback.Live_deployment -> "deployment"
  | Sol_cli_rollback.Live_rollout -> "rollout"
  | Sol_cli_rollback.Live_cronjob -> "cronjob"
;;

let test_live_resource_and_jsonpath_table () =
  List.iter
    (fun (kind, expected_resource, expected_jsonpath) ->
       let resource, jsonpath = Sol_cli_rollback.live_resource_and_jsonpath kind in
       Alcotest.(check string)
         (live_kind_label kind ^ " resource")
         expected_resource
         resource;
       Alcotest.(check string)
         (live_kind_label kind ^ " jsonpath")
         expected_jsonpath
         jsonpath)
    [ ( Sol_cli_rollback.Live_deployment
      , "deployment"
      , "{.spec.template.metadata.labels.release}" )
    ; Sol_cli_rollback.Live_rollout, "rollout", "{.spec.template.metadata.labels.release}"
    ; ( Sol_cli_rollback.Live_cronjob
      , "cronjob"
      , "{.spec.jobTemplate.spec.template.metadata.labels.release}" )
    ]
;;

let verify_release : Sol_cli_release.t =
  { release_id = "r-2222222222222222"
  ; workspace = "myapp"
  ; environment = None
  ; workloads = []
  ; migrations = []
  ; apply_mode = Sol_cli_release.Direct
  }
;;

let test_check_apply_mode_allows_direct () =
  Sol_cli_rollback.check_apply_mode ~release:verify_release
  |> Result.iter_error (fun e ->
    Alcotest.fail (Sol_cli_rollback.apply_mode_check_error_to_string e))
;;

let test_check_apply_mode_refuses_gitops () =
  let release = { verify_release with apply_mode = Sol_cli_release.Gitops } in
  match Sol_cli_rollback.check_apply_mode ~release with
  | Ok () -> Alcotest.fail "expected a GitOps-owned release to be refused"
  | Error e ->
    let msg = Sol_cli_rollback.apply_mode_check_error_to_string e in
    assert (contains (Str.regexp "GitOps") msg);
    assert (contains (Str.regexp release.release_id) msg)
;;

let id kind namespace name : Sol_cli_rollback.workload_identity =
  { kind; namespace; name }
;;

let expected_specs = [ ledger_spec; billing_spec ]

let expected_applied =
  List.map (fun spec -> spec, verify_release.release_id) expected_specs
;;

let ledger_id = id Sol_cli_rollback.Live_deployment "myapp-payments" "ledger-svc"
let billing_id = id Sol_cli_rollback.Live_rollout "myapp-payments" "billing-svc"

let test_verify_workloads_ok_when_set_matches () =
  let live =
    [ ledger_id, verify_release.release_id; billing_id, verify_release.release_id ]
  in
  let report = Sol_cli_rollback.verify_workloads ~expected:expected_applied ~live in
  Alcotest.(check bool)
    "workload set matches"
    true
    (Sol_cli_rollback.workload_report_ok report)
;;

let test_verify_workloads_reports_unexpected () =
  let stale_id = id Sol_cli_rollback.Live_deployment "myapp-payments" "fraud-svc" in
  let live =
    [ ledger_id, verify_release.release_id
    ; billing_id, verify_release.release_id
    ; stale_id, "r-9999999999999999"
    ]
  in
  let report = Sol_cli_rollback.verify_workloads ~expected:expected_applied ~live in
  Alcotest.(check bool) "not ok" false (Sol_cli_rollback.workload_report_ok report);
  let msg = Sol_cli_rollback.workload_report_to_string ~release:verify_release report in
  assert (contains (Str.regexp "unexpected workload") msg);
  assert (contains (Str.regexp "fraud-svc") msg)
;;

let test_verify_workloads_reports_missing () =
  let live = [ billing_id, verify_release.release_id ] in
  let report = Sol_cli_rollback.verify_workloads ~expected:expected_applied ~live in
  Alcotest.(check bool) "not ok" false (Sol_cli_rollback.workload_report_ok report);
  let msg = Sol_cli_rollback.workload_report_to_string ~release:verify_release report in
  assert (contains (Str.regexp "workload missing") msg);
  assert (contains (Str.regexp "ledger-svc") msg)
;;

let test_verify_workloads_reports_label_mismatch () =
  let live = [ ledger_id, "r-9999999999999999"; billing_id, verify_release.release_id ] in
  let report = Sol_cli_rollback.verify_workloads ~expected:expected_applied ~live in
  Alcotest.(check bool) "not ok" false (Sol_cli_rollback.workload_report_ok report);
  let msg = Sol_cli_rollback.workload_report_to_string ~release:verify_release report in
  assert (contains (Str.regexp "workload state mismatch") msg);
  assert (contains (Str.regexp "r-9999999999999999") msg)
;;

let test_verify_workloads_distinguishes_kind () =
  let ledger_as_rollout =
    id Sol_cli_rollback.Live_rollout "myapp-payments" "ledger-svc"
  in
  let live =
    [ ledger_as_rollout, verify_release.release_id
    ; billing_id, verify_release.release_id
    ]
  in
  let report = Sol_cli_rollback.verify_workloads ~expected:expected_applied ~live in
  Alcotest.(check bool) "not ok" false (Sol_cli_rollback.workload_report_ok report);
  let msg = Sol_cli_rollback.workload_report_to_string ~release:verify_release report in
  assert (contains (Str.regexp "workload missing") msg);
  assert (contains (Str.regexp "unexpected workload") msg)
;;

let fn_spec : Sol_cli_deployment_plan.service_spec =
  { ledger_spec with
    source_name = "invoice_fn"
  ; k8s_name = k8s_name "invoice-fn"
  ; primitive = Sol_cli_deployment_plan.Fn
  ; schedule = Some "0 * * * *"
  ; scheduled_concurrency = Sol_cli_toml.Forbid
  ; backoff_limit = 0
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; rollout_strategy = None
  ; progressive_delivery = None
  }
;;

let fn_release : Sol_cli_release.t =
  { release_id = "r-3333333333333333"
  ; workspace = "myapp"
  ; environment = None
  ; workloads =
      [ Sol_cli_release.applied_by
          "r-3333333333333333"
          (Sol_cli_deployment_plan.release_workload_of_spec fn_spec)
      ]
  ; migrations = []
  ; apply_mode = Sol_cli_release.Direct
  }
;;

let test_fn_reconstructs_and_verifies_as_cronjob () =
  match Sol_cli_rollback.service_specs_of_release fn_release with
  | Error msg -> Alcotest.fail msg
  | Ok [ (got, applied_by) ] ->
    Alcotest.(check string) "provenance" fn_release.release_id applied_by;
    Alcotest.(check bool)
      "primitive is still Fn"
      true
      (got.primitive = Sol_cli_deployment_plan.Fn);
    Alcotest.(check (option string)) "schedule preserved" fn_spec.schedule got.schedule;
    Alcotest.(check bool)
      "scheduled concurrency preserved"
      true
      (got.scheduled_concurrency = Sol_cli_toml.Forbid);
    Alcotest.(check int) "backoff limit preserved" 0 got.backoff_limit;
    let rendered =
      match
        Sol_cli_deployment_render.render_spec
          ~workspace:"myapp"
          ~release_id:
            (match Sol_cli_release_id.of_string fn_release.release_id with
             | Ok id -> id
             | Error msg -> Alcotest.fail msg)
          ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder
          got
      with
      | Ok (_ns_yaml, body) -> body
      | Error msg -> Alcotest.fail msg
    in
    Alcotest.(check bool)
      "rendered CronJob keeps concurrencyPolicy: Forbid"
      true
      (contains (Str.regexp_string "concurrencyPolicy: Forbid") rendered);
    Alcotest.(check bool)
      "rendered CronJob keeps backoffLimit: 0"
      true
      (contains (Str.regexp_string "backoffLimit: 0") rendered);
    Alcotest.(check bool)
      "live kind is CronJob"
      true
      (Sol_cli_rollback.live_kind_of_service got = Sol_cli_rollback.Live_cronjob);
    let live =
      [ ( id Sol_cli_rollback.Live_cronjob "myapp-payments" "invoice-fn"
        , fn_release.release_id )
      ]
    in
    let report =
      Sol_cli_rollback.verify_workloads ~expected:[ got, fn_release.release_id ] ~live
    in
    Alcotest.(check bool)
      "a CronJob is part of the verified set, not skipped"
      true
      (Sol_cli_rollback.workload_report_ok report)
  | Ok specs -> Alcotest.failf "expected 1 reconstructed spec, got %d" (List.length specs)
;;

let test_reconstruction_rejects_invalid_persistence () =
  let workload = List.hd gate_release.workloads in
  let invalid_workload =
    { workload with
      Sol_cli_release_id.spec =
        { workload.Sol_cli_release_id.spec with
          replicas = 2
        ; volumes = [ "data", "/data", "10Gi", "ReadWriteOnce" ]
        }
    }
  in
  let invalid = { gate_release with workloads = [ invalid_workload ] } in
  match Sol_cli_rollback.service_specs_of_release invalid with
  | Ok _ -> Alcotest.fail "expected rollback reconstruction to reject persistence"
  | Error msg -> assert (contains (Str.regexp "set replicas = 1") msg)
;;

let test_recreate_strategy_reconstructs () =
  let specs = reconstruct_ok () in
  let ledger =
    List.find
      (fun ((s : Sol_cli_deployment_plan.service_spec), _) ->
         s.source_name = "ledger_svc")
      specs
    |> fst
  in
  Alcotest.(check bool)
    "recreate preserved"
    true
    (ledger.rollout_strategy = Some Sol_cli_toml.Recreate)
;;

let deployment_payload =
  `Assoc
    [ ( "items"
      , `List
          [ `Assoc
              [ ( "metadata"
                , `Assoc
                    [ "namespace", `String "myapp-payments"
                    ; "name", `String "ledger-svc"
                    ] )
              ; ( "spec"
                , `Assoc
                    [ ( "template"
                      , `Assoc
                          [ ( "metadata"
                            , `Assoc
                                [ ( "labels"
                                  , `Assoc
                                      [ "workspace", `String "myapp"
                                      ; "release", `String "r-1"
                                      ] )
                                ] )
                          ] )
                    ] )
              ]
          ; `Assoc
              [ ( "metadata"
                , `Assoc
                    [ "namespace", `String "myapp-payments"; "name", `String "other-svc" ]
                )
              ; ( "spec"
                , `Assoc
                    [ ( "template"
                      , `Assoc
                          [ ( "metadata"
                            , `Assoc
                                [ ( "labels"
                                  , `Assoc
                                      [ "workspace", `String "someoneelse"
                                      ; "release", `String "r-9"
                                      ] )
                                ] )
                          ] )
                    ] )
              ]
          ; `Assoc
              [ ( "metadata"
                , `Assoc [ "namespace", `String "kube-system"; "name", `String "coredns" ]
                )
              ]
          ] )
    ]
;;

let test_workload_rows_of_payload_deployment () =
  let rows =
    Sol_cli_rollback.workload_rows_of_payload
      ~kind:Sol_cli_rollback.Live_deployment
      ~workspace:"myapp"
      deployment_payload
    |> Result.get_ok
  in
  Alcotest.(check int) "only the workspace-matching item" 1 (List.length rows);
  let identity, release = List.hd rows in
  Alcotest.(check bool) "kind" true (identity.kind = Sol_cli_rollback.Live_deployment);
  Alcotest.(check string) "namespace" "myapp-payments" identity.namespace;
  Alcotest.(check string) "name" "ledger-svc" identity.name;
  Alcotest.(check string) "release label" "r-1" release
;;

let test_workload_rows_of_payload_cronjob_path () =
  let as_deployment =
    Sol_cli_rollback.workload_rows_of_payload
      ~kind:Sol_cli_rollback.Live_cronjob
      ~workspace:"myapp"
      deployment_payload
    |> Result.get_ok
  in
  Alcotest.(check int)
    "deployment payload has no cronjob pod template"
    0
    (List.length as_deployment)
;;

let test_workload_rows_of_payload_requires_items () =
  (match
     Sol_cli_rollback.workload_rows_of_payload
       ~kind:Sol_cli_rollback.Live_deployment
       ~workspace:"myapp"
       (`Assoc [ "kind", `String "List" ])
   with
   | Ok _ -> Alcotest.fail "a payload without items read as an answer"
   | Error _ -> ());
  Alcotest.(check int)
    "an empty items list is the empty answer"
    0
    (Sol_cli_rollback.workload_rows_of_payload
       ~kind:Sol_cli_rollback.Live_deployment
       ~workspace:"myapp"
       (`Assoc [ "items", `List [] ])
     |> Result.get_ok
     |> List.length)
;;

let test_workload_rows_of_payload_sanitizes_workspace () =
  let payload =
    `Assoc
      [ ( "items"
        , `List
            [ `Assoc
                [ ( "metadata"
                  , `Assoc
                      [ "namespace", `String "myapp-payments"
                      ; "name", `String "ledger-svc"
                      ] )
                ; ( "spec"
                  , `Assoc
                      [ ( "template"
                        , `Assoc
                            [ ( "metadata"
                              , `Assoc
                                  [ ( "labels"
                                    , `Assoc
                                        [ "workspace", `String "my-app"
                                        ; "release", `String "r-1"
                                        ] )
                                  ] )
                            ] )
                      ] )
                ]
            ] )
      ]
  in
  let rows =
    Sol_cli_rollback.workload_rows_of_payload
      ~kind:Sol_cli_rollback.Live_deployment
      ~workspace:"My_App"
      payload
    |> Result.get_ok
  in
  Alcotest.(check int) "matches the sanitized workspace label" 1 (List.length rows)
;;

let test_workload_rows_of_payload_cronjob () =
  let payload =
    `Assoc
      [ ( "items"
        , `List
            [ `Assoc
                [ ( "metadata"
                  , `Assoc
                      [ "namespace", `String "myapp-billing"
                      ; "name", `String "invoice-fn"
                      ] )
                ; ( "spec"
                  , `Assoc
                      [ ( "jobTemplate"
                        , `Assoc
                            [ ( "spec"
                              , `Assoc
                                  [ ( "template"
                                    , `Assoc
                                        [ ( "metadata"
                                          , `Assoc
                                              [ ( "labels"
                                                , `Assoc
                                                    [ "workspace", `String "myapp"
                                                    ; "release", `String "r-2"
                                                    ] )
                                              ] )
                                        ] )
                                  ] )
                            ] )
                      ] )
                ]
            ] )
      ]
  in
  let rows =
    Sol_cli_rollback.workload_rows_of_payload
      ~kind:Sol_cli_rollback.Live_cronjob
      ~workspace:"myapp"
      payload
    |> Result.get_ok
  in
  Alcotest.(check int) "one cronjob row" 1 (List.length rows);
  let identity, release = List.hd rows in
  Alcotest.(check string) "name" "invoice-fn" identity.name;
  Alcotest.(check string) "release label" "r-2" release
;;

let test_pointer_report_ok () =
  Alcotest.(check bool)
    "ok"
    true
    (Sol_cli_rollback.pointer_report_ok
       { pointer_actual = verify_release.release_id; pointer_ok = true });
  Alcotest.(check bool)
    "not ok"
    false
    (Sol_cli_rollback.pointer_report_ok { pointer_actual = "r-x"; pointer_ok = false })
;;

let test_pointer_report_to_string_uses_canonical_name () =
  let report = { Sol_cli_rollback.pointer_actual = ""; pointer_ok = false } in
  let msg = Sol_cli_rollback.pointer_report_to_string ~release:verify_release report in
  assert (contains (Str.regexp "sol-release-current-myapp") msg);
  assert (contains (Str.regexp "<none>") msg);
  let release = { verify_release with workspace = "CI_Smoke" } in
  let msg = Sol_cli_rollback.pointer_report_to_string ~release report in
  assert (contains (Str.regexp "sol-release-current-ci-smoke") msg);
  assert (not (contains (Str.regexp_string "CI_Smoke") msg))
;;

let transaction_release ~apply_mode : Sol_cli_release.t =
  { release_id = "r-3333333333333333"
  ; workspace = "myapp"
  ; environment = None
  ; workloads = []
  ; migrations = []
  ; apply_mode
  }
;;

let recording_deps
      ?(live = [])
      ?(prune_result = Ok ())
      ?ensure_held
      ?applied_migrations
      ?(record_consumer_groups = fun _ -> Ok ())
      ()
  =
  let calls = ref [] in
  let pruned = ref None in
  let record name = calls := name :: !calls in
  let ensure_held =
    match ensure_held with
    | Some f ->
      fun () ->
        record "ensure_held";
        f ()
    | None ->
      fun () ->
        record "ensure_held";
        Ok ()
  in
  let applied_migrations =
    match applied_migrations with
    | Some f ->
      fun () ->
        record "applied_migrations";
        f ()
    | None ->
      fun () ->
        record "applied_migrations";
        Ok []
  in
  let deps : Sol_cli_rollback.transaction_deps =
    { ensure_held
    ; applied_migrations
    ; apply =
        (fun _specs ->
          record "apply";
          Ok ())
    ; live_workloads =
        (fun () ->
          record "live_workloads";
          Ok live)
    ; prune =
        (fun surplus ->
          record "prune";
          pruned := Some surplus;
          prune_result)
    ; move_pointer =
        (fun () ->
          record "move_pointer";
          Ok ())
    ; verify_pointer =
        (fun () ->
          record "verify_pointer";
          { Sol_cli_rollback.pointer_actual = "r-3333333333333333"; pointer_ok = true })
    ; record_consumer_groups =
        (fun groups ->
          record (Printf.sprintf "record_consumer_groups:%s" (String.concat "," groups));
          record_consumer_groups groups)
    }
  in
  calls, pruned, deps
;;

let test_execute_success_calls_every_dep_in_order () =
  let calls, pruned, deps = recording_deps () in
  let release = transaction_release ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Error msg -> Alcotest.fail msg
  | Ok () ->
    Alcotest.(check (list string))
      "ownership is re-verified before each mutation"
      [ "applied_migrations"
      ; "ensure_held"
      ; "apply"
      ; "live_workloads"
      ; "ensure_held"
      ; "prune"
      ; "ensure_held"
      ; "move_pointer"
      ; "verify_pointer"
      ; "record_consumer_groups:"
      ]
      (List.rev !calls);
    Alcotest.(check int) "prune ran with no surplus" 0 (List.length (Option.get !pruned))
;;

let worker_spec ?(domain = "comms") ?(name = "notify_worker") ()
  : Sol_cli_deployment_plan.service_spec
  =
  { ledger_spec with
    domain
  ; source_name = name
  ; k8s_name = k8s_name (String.concat "-" (String.split_on_char '_' name))
  ; namespace = namespace ~workspace:"myapp" ~domain
  ; primitive = Sol_cli_deployment_plan.Worker
  ; consumes_kafka = true
  }
;;

let release_with_workloads ~apply_mode specs : Sol_cli_release.t =
  let base = transaction_release ~apply_mode in
  { base with
    workloads =
      List.map
        (fun spec ->
           Sol_cli_release.applied_by
             base.release_id
             (Sol_cli_deployment_plan.release_workload_of_spec spec))
        specs
  }
;;

let live_for specs =
  List.map
    (fun spec -> Sol_cli_rollback.identity_of_spec spec, "r-3333333333333333")
    specs
;;

let test_execute_records_the_restored_consumer_groups () =
  let groups_for specs =
    let calls, _pruned, deps = recording_deps ~live:(live_for specs) () in
    let release = release_with_workloads ~apply_mode:Sol_cli_release.Direct specs in
    match
      Sol_cli_rollback.execute
        ~release
        ~migrations_dir:"unused"
        ~current_migrations:[]
        ~deps
    with
    | Error msg -> Alcotest.fail msg
    | Ok () ->
      (match !calls with
       | last :: _ -> last
       | [] -> Alcotest.fail "no deps were called")
  in
  let notify = worker_spec () in
  let fulfill = worker_spec ~domain:"logistics" ~name:"fulfillment_worker" () in
  Alcotest.(check string)
    "rolling back to A+B records both workers' groups, last, after the pointer verified"
    "record_consumer_groups:myapp.comms.notify_worker,myapp.logistics.fulfillment_worker"
    (groups_for [ notify; fulfill ]);
  Alcotest.(check string)
    "rolling back to A records only A, so the next deploy's removal check describes the \
     restored set"
    "record_consumer_groups:myapp.comms.notify_worker"
    (groups_for [ notify ]);
  Alcotest.(check string)
    "a non-worker release records no groups"
    "record_consumer_groups:"
    (groups_for [ ledger_spec ])
;;

let test_execute_leaves_the_guard_alone_when_verification_fails () =
  let calls, _pruned, deps = recording_deps ~live:[] () in
  let release =
    release_with_workloads ~apply_mode:Sol_cli_release.Direct [ worker_spec () ]
  in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Alcotest.fail "expected the missing workload to block the rollback"
  | Error _ ->
    Alcotest.(check bool)
      "the guard record still describes the release that is still live"
      true
      (List.for_all
         (fun call -> not (Sol_cli_string.contains ~needle:"record_consumer_groups" call))
         !calls)
;;

let test_execute_reports_an_uncorrected_guard_record () =
  let notify = worker_spec () in
  let calls, _pruned, deps =
    recording_deps
      ~live:(live_for [ notify ])
      ~record_consumer_groups:(fun _ -> Error "the ConfigMap is forbidden")
      ()
  in
  let release = release_with_workloads ~apply_mode:Sol_cli_release.Direct [ notify ] in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Alcotest.fail "an uncorrected guard record must be reported"
  | Error msg ->
    assert (contains (Str.regexp_string "rollback incomplete") msg);
    assert (contains (Str.regexp_string "could not be corrected") msg);
    assert (contains (Str.regexp_string "the ConfigMap is forbidden") msg);
    Alcotest.(check bool)
      "the rollback itself did happen, so the pointer was moved"
      true
      (List.exists (fun call -> String.equal call "move_pointer") !calls)
;;

let test_execute_apply_mode_refusal_calls_no_deps () =
  let calls, _pruned, deps = recording_deps () in
  let release = transaction_release ~apply_mode:Sol_cli_release.Gitops in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Alcotest.fail "expected a GitOps-owned release to be refused"
  | Error msg ->
    assert (contains (Str.regexp "GitOps") msg);
    Alcotest.(check (list string)) "no dep was ever called" [] !calls
;;

let test_execute_migration_boundary_refusal_calls_no_deps () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql; "0002_drop_col.sql", contract_sql ]
    (fun migrations_dir ->
       let calls, _pruned, deps = recording_deps () in
       let release =
         { (transaction_release ~apply_mode:Sol_cli_release.Direct) with
           migrations = [ "0001_init.sql" ]
         }
       in
       match
         Sol_cli_rollback.execute
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql"; "0002_drop_col.sql" ]
           ~deps
       with
       | Ok () -> Alcotest.fail "expected a contracting migration to block the rollback"
       | Error msg ->
         assert (contains (Str.regexp "0002_drop_col.sql") msg);
         Alcotest.(check (list string)) "no dep was ever called" [] !calls)
;;

let test_execute_unexpected_workload_triggers_prune_then_completes () =
  let bogus_live : Sol_cli_rollback.workload_identity * string =
    ( { Sol_cli_rollback.kind = Sol_cli_rollback.Live_deployment
      ; namespace = "myapp-payments"
      ; name = "ghost-svc"
      }
    , "r-3333333333333333" )
  in
  let calls, pruned, deps = recording_deps ~live:[ bogus_live ] () in
  let release = transaction_release ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Error msg -> Alcotest.fail msg
  | Ok () ->
    Alcotest.(check (list string))
      "apply, live_workloads, prune, move_pointer, verify_pointer all ran"
      [ "applied_migrations"
      ; "ensure_held"
      ; "apply"
      ; "live_workloads"
      ; "ensure_held"
      ; "prune"
      ; "ensure_held"
      ; "move_pointer"
      ; "verify_pointer"
      ; "record_consumer_groups:"
      ]
      (List.rev !calls);
    (match !pruned with
     | None -> Alcotest.fail "prune was never called"
     | Some surplus ->
       Alcotest.(check int)
         "exactly the bogus workload was pruned"
         1
         (List.length surplus);
       let id, _ = List.hd surplus in
       Alcotest.(check string) "pruned name" "ghost-svc" id.name)
;;

let test_execute_prune_failure_skips_pointer_move () =
  let bogus_live : Sol_cli_rollback.workload_identity * string =
    ( { Sol_cli_rollback.kind = Sol_cli_rollback.Live_deployment
      ; namespace = "myapp-payments"
      ; name = "ghost-svc"
      }
    , "r-3333333333333333" )
  in
  let calls, _pruned, deps =
    recording_deps ~live:[ bogus_live ] ~prune_result:(Error "boom") ()
  in
  let release = transaction_release ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Alcotest.fail "expected the prune failure to block the pointer move"
  | Error msg ->
    assert (contains (Str.regexp "boom") msg);
    assert (contains (Str.regexp "pointer was left unchanged") msg);
    Alcotest.(check (list string))
      "apply, live_workloads, prune ran; move_pointer/verify_pointer never did"
      [ "applied_migrations"
      ; "ensure_held"
      ; "apply"
      ; "live_workloads"
      ; "ensure_held"
      ; "prune"
      ]
      (List.rev !calls)
;;

let test_execute_applied_state_unavailable_skips_every_mutation () =
  let calls, pruned, deps =
    recording_deps ~applied_migrations:(fun () -> Error "no cluster") ()
  in
  let release = transaction_release ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Alcotest.fail "expected the unreadable applied state to block the rollback"
  | Error msg ->
    assert (contains (Str.regexp "applied migration state") msg);
    Alcotest.(check (list string))
      "only the applied-state read ran"
      [ "applied_migrations" ]
      (List.rev !calls);
    Alcotest.(check bool) "prune never called" true (!pruned = None)
;;

let ghost_live : Sol_cli_rollback.workload_identity * string =
  ( { Sol_cli_rollback.kind = Sol_cli_rollback.Live_deployment
    ; namespace = "myapp-payments"
    ; name = "ghost-svc"
    }
  , "r-3333333333333333" )
;;

let ownership_lost_after n =
  let calls = ref 0 in
  fun () ->
    incr calls;
    if !calls >= n
    then Error "lost the boundary lease to rollback run-takeover (BUG-071)"
    else Ok ()
;;

let test_execute_lost_ownership_after_apply_skips_prune_and_pointer () =
  let calls, pruned, deps =
    recording_deps ~live:[ ghost_live ] ~ensure_held:(ownership_lost_after 2) ()
  in
  let release = transaction_release ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Alcotest.fail "expected the lost lease to stop the transaction"
  | Error msg ->
    assert (contains (Str.regexp "lost the boundary lease") msg);
    Alcotest.(check (list string))
      "the takeover stopped the transaction before prune"
      [ "applied_migrations"; "ensure_held"; "apply"; "live_workloads"; "ensure_held" ]
      (List.rev !calls);
    Alcotest.(check bool) "prune never called" true (!pruned = None)
;;

let test_execute_lost_ownership_after_prune_skips_pointer_move () =
  let calls, _pruned, deps =
    recording_deps ~live:[ ghost_live ] ~ensure_held:(ownership_lost_after 3) ()
  in
  let release = transaction_release ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Alcotest.fail "expected the lost lease to block the pointer move"
  | Error msg ->
    assert (contains (Str.regexp "lost the boundary lease") msg);
    Alcotest.(check (list string))
      "apply and prune ran; the pointer was never moved"
      [ "applied_migrations"
      ; "ensure_held"
      ; "apply"
      ; "live_workloads"
      ; "ensure_held"
      ; "prune"
      ; "ensure_held"
      ]
      (List.rev !calls)
;;

let transaction_release_with_ledger ~apply_mode : Sol_cli_release.t =
  let base = transaction_release ~apply_mode in
  { base with
    workloads =
      [ Sol_cli_release.applied_by
          base.release_id
          (Sol_cli_deployment_plan.release_workload_of_spec ledger_spec)
      ]
  }
;;

let test_execute_missing_workload_skips_prune_and_pointer_move () =
  let calls, pruned, deps = recording_deps ~live:[] () in
  let release = transaction_release_with_ledger ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Alcotest.fail "expected the missing workload to block the pointer move"
  | Error msg ->
    assert (contains (Str.regexp "ledger-svc") msg);
    assert (contains (Str.regexp "pointer was left unchanged") msg);
    Alcotest.(check (list string))
      "apply and live_workloads ran; prune/move_pointer/verify_pointer never did"
      [ "applied_migrations"; "ensure_held"; "apply"; "live_workloads" ]
      (List.rev !calls);
    Alcotest.(check bool) "prune never called" true (!pruned = None)
;;

let test_execute_mismatched_workload_skips_prune_and_pointer_move () =
  let calls, pruned, deps = recording_deps ~live:[ ledger_id, "r-9999999999999999" ] () in
  let release = transaction_release_with_ledger ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Alcotest.fail "expected the label mismatch to block the pointer move"
  | Error msg ->
    assert (contains (Str.regexp "ledger-svc") msg);
    assert (contains (Str.regexp "pointer was left unchanged") msg);
    Alcotest.(check (list string))
      "apply and live_workloads ran; prune/move_pointer/verify_pointer never did"
      [ "applied_migrations"; "ensure_held"; "apply"; "live_workloads" ]
      (List.rev !calls);
    Alcotest.(check bool) "prune never called" true (!pruned = None)
;;

let test_commit_matches_exact () =
  Alcotest.(check bool)
    "exact match"
    true
    (Sol_cli_rollback.commit_matches ~commit:"abc1234" "abc1234")
;;

let test_commit_matches_full_resolves_stored_short () =
  Alcotest.(check bool)
    "full sha resolves a short stored sha"
    true
    (Sol_cli_rollback.commit_matches
       ~commit:"abc1234def5678900000000000000000000000"
       "abc1234")
;;

let test_commit_matches_short_resolves_stored_full () =
  Alcotest.(check bool)
    "short input resolves a full stored sha"
    true
    (Sol_cli_rollback.commit_matches
       ~commit:"abc1234"
       "abc1234def5678900000000000000000000000")
;;

let test_commit_matches_case_insensitive () =
  Alcotest.(check bool)
    "case insensitive"
    true
    (Sol_cli_rollback.commit_matches ~commit:"ABC1234" "abc1234")
;;

let test_commit_matches_mismatch () =
  Alcotest.(check bool)
    "mismatch"
    false
    (Sol_cli_rollback.commit_matches ~commit:"abc1234" "def5678")
;;

let test_commit_matches_empty_never_matches () =
  Alcotest.(check bool)
    "empty commit"
    false
    (Sol_cli_rollback.commit_matches ~commit:"" "abc1234");
  Alcotest.(check bool)
    "empty stored"
    false
    (Sol_cli_rollback.commit_matches ~commit:"abc1234" "")
;;

let deployment_event
      ?(release_id = "r-0123456789abcdef")
      ?(git_commit = "abc1234")
      ?(target = Some "prod/aws/us-east-1")
      ?(requested_scope = "workspace")
      ?(outcome = Sol_cli_deployment.Applied)
      ?(entropy = "seed")
      ()
  : Sol_cli_deployment.t
  =
  { deployment_id = Sol_cli_deployment_id.create ~now:1767225600.0 ~entropy
  ; release_id = Result.get_ok (Sol_cli_release_id.of_string release_id)
  ; workspace = "myworkspace"
  ; environment = Some "prod"
  ; created_at = "2026-01-01T00:00:00Z"
  ; git_commit
  ; git_dirty = false
  ; actor = Some "ci"
  ; target
  ; mode = "customer_cloud"
  ; requested_scope
  ; profile = None
  ; outcome
  }
;;

let test_resolve_commit_no_match_is_no_match () =
  match
    Sol_cli_rollback.resolve_commit
      ~commit:"abc1234"
      ~target:"prod/aws/us-east-1"
      [ deployment_event ~git_commit:"def5678" () ]
  with
  | Sol_cli_rollback.Commit_no_match -> ()
  | _ -> Alcotest.fail "expected Commit_no_match"
;;

let test_resolve_commit_unambiguous_resolves () =
  match
    Sol_cli_rollback.resolve_commit
      ~commit:"abc1234"
      ~target:"prod/aws/us-east-1"
      [ deployment_event ~release_id:"r-0123456789abcdef" () ]
  with
  | Sol_cli_rollback.Commit_resolved release_id ->
    Alcotest.(check string) "resolved release id" "r-0123456789abcdef" release_id
  | _ -> Alcotest.fail "expected Commit_resolved"
;;

let test_resolve_commit_ambiguous_lists_candidates () =
  match
    Sol_cli_rollback.resolve_commit
      ~commit:"abc1234"
      ~target:"prod/aws/us-east-1"
      [ deployment_event
          ~release_id:"r-0123456789abcdef"
          ~requested_scope:"workspace"
          ~entropy:"a"
          ()
      ; deployment_event
          ~release_id:"r-fedcba9876543210"
          ~requested_scope:"payments"
          ~entropy:"b"
          ()
      ]
  with
  | Sol_cli_rollback.Commit_ambiguous candidates ->
    Alcotest.(check int) "two candidates" 2 (List.length candidates);
    Alcotest.(check bool)
      "both release ids present"
      true
      (List.mem_assoc "r-0123456789abcdef" candidates
       && List.mem_assoc "r-fedcba9876543210" candidates)
  | _ -> Alcotest.fail "expected Commit_ambiguous"
;;

let test_resolve_commit_repeated_deploys_dedup () =
  match
    Sol_cli_rollback.resolve_commit
      ~commit:"abc1234"
      ~target:"prod/aws/us-east-1"
      [ deployment_event ~release_id:"r-0123456789abcdef" ~entropy:"a" ()
      ; deployment_event ~release_id:"r-0123456789abcdef" ~entropy:"b" ()
      ]
  with
  | Sol_cli_rollback.Commit_resolved release_id ->
    Alcotest.(check string) "resolved release id" "r-0123456789abcdef" release_id
  | _ -> Alcotest.fail "expected Commit_resolved (deduped)"
;;

let test_resolve_commit_scope_narrows_candidates () =
  let events =
    [ deployment_event
        ~release_id:"r-0123456789abcdef"
        ~requested_scope:"workspace"
        ~entropy:"a"
        ()
    ; deployment_event
        ~release_id:"r-fedcba9876543210"
        ~requested_scope:"payments"
        ~entropy:"b"
        ()
    ]
  in
  match
    Sol_cli_rollback.resolve_commit
      ~commit:"abc1234"
      ~scope:"payments"
      ~target:"prod/aws/us-east-1"
      events
  with
  | Sol_cli_rollback.Commit_resolved release_id ->
    Alcotest.(check string)
      "resolved to the scoped release"
      "r-fedcba9876543210"
      release_id
  | _ -> Alcotest.fail "expected Commit_resolved narrowed by scope"
;;

let test_resolve_commit_wrong_target_excluded () =
  match
    Sol_cli_rollback.resolve_commit
      ~commit:"abc1234"
      ~target:"staging/aws/us-east-1"
      [ deployment_event ~target:(Some "prod/aws/us-east-1") () ]
  with
  | Sol_cli_rollback.Commit_no_match -> ()
  | _ -> Alcotest.fail "expected Commit_no_match: different target"
;;

let test_resolve_commit_apply_failed_excluded () =
  match
    Sol_cli_rollback.resolve_commit
      ~commit:"abc1234"
      ~target:"prod/aws/us-east-1"
      [ deployment_event ~outcome:Sol_cli_deployment.Apply_failed () ]
  with
  | Sol_cli_rollback.Commit_no_match -> ()
  | _ -> Alcotest.fail "expected Commit_no_match: only Apply_failed events exist"
;;

let test_resolve_commit_invalid_scope () =
  match
    Sol_cli_rollback.resolve_commit
      ~commit:"abc1234"
      ~scope:"a/b/c"
      ~target:"prod/aws/us-east-1"
      []
  with
  | Sol_cli_rollback.Commit_invalid _ -> ()
  | _ -> Alcotest.fail "expected Commit_invalid: malformed --scope"
;;

let test_sequential_application_stops_on_error () =
  let visited = ref [] in
  let apply spec =
    visited := spec :: !visited;
    if spec = 2 then Error "apply failed" else Ok ()
  in
  let result = [ 1; 2; 3 ] |> Sol_cli_result.map_list apply |> Result.map ignore in
  Alcotest.(check (result unit string)) "first error" (Error "apply failed") result;
  Alcotest.(check (list int))
    "sequential, stops before third"
    [ 1; 2 ]
    (List.rev !visited)
;;

let () =
  Alcotest.run
    "rollback"
    [ ( "reconstruction_gate"
      , [ Alcotest.test_case "A: decode correctness" `Quick test_gate_a_decode_correctness
        ; Alcotest.test_case
            "B: identity correctness"
            `Quick
            test_gate_b_identity_correctness
        ; Alcotest.test_case "C: render correctness" `Quick test_gate_c_render_correctness
        ; Alcotest.test_case
            "failure: unknown rollout encoding"
            `Quick
            test_gate_failure_unknown_rollout_encoding
        ; Alcotest.test_case
            "failure: invalid cpu quantity"
            `Quick
            test_gate_failure_invalid_cpu
        ; Alcotest.test_case
            "failure: invalid persistence"
            `Quick
            test_reconstruction_rejects_invalid_persistence
        ] )
    ; ( "migration_boundary_check"
      , [ Alcotest.test_case
            "no new migrations passes"
            `Quick
            test_migration_boundary_no_new_migrations_passes
        ; Alcotest.test_case
            "new expand migration passes"
            `Quick
            test_migration_boundary_new_expand_passes
        ; Alcotest.test_case
            "new contract migration blocks"
            `Quick
            test_migration_boundary_new_contract_blocks
        ; Alcotest.test_case
            "new undeclared migration blocks"
            `Quick
            test_migration_boundary_undeclared_new_migration_blocks
        ; Alcotest.test_case
            "already-recorded contract is ignored"
            `Quick
            test_migration_boundary_ignores_already_recorded_contract
        ; Alcotest.test_case
            "applied migration absent from the checkout blocks (BUG-078)"
            `Quick
            test_migration_boundary_applied_beyond_release_absent_locally_blocks
        ; Alcotest.test_case
            "applied expansion beyond the release passes (BUG-078)"
            `Quick
            test_migration_boundary_applied_expansion_beyond_release_passes
        ; Alcotest.test_case
            "unreadable applied state blocks (BUG-078)"
            `Quick
            test_migration_boundary_applied_state_unavailable_blocks
        ] )
    ; ( "live_kind_of_service"
      , [ Alcotest.test_case
            "primitive/progressive_delivery table"
            `Quick
            test_live_kind_of_service_table
        ; Alcotest.test_case
            "resource + jsonpath table"
            `Quick
            test_live_resource_and_jsonpath_table
        ] )
    ; ( "sequential_application"
      , [ Alcotest.test_case
            "stops on first error"
            `Quick
            test_sequential_application_stops_on_error
        ] )
    ; ( "apply_mode_refusal"
      , [ Alcotest.test_case "allows Direct" `Quick test_check_apply_mode_allows_direct
        ; Alcotest.test_case "refuses Gitops" `Quick test_check_apply_mode_refuses_gitops
        ] )
    ; ( "workload_set_verification"
      , [ Alcotest.test_case
            "ok when the set matches"
            `Quick
            test_verify_workloads_ok_when_set_matches
        ; Alcotest.test_case
            "reports an unexpected workload"
            `Quick
            test_verify_workloads_reports_unexpected
        ; Alcotest.test_case
            "reports a missing workload"
            `Quick
            test_verify_workloads_reports_missing
        ; Alcotest.test_case
            "reports a label mismatch"
            `Quick
            test_verify_workloads_reports_label_mismatch
        ; Alcotest.test_case
            "distinguishes Deployment from Rollout"
            `Quick
            test_verify_workloads_distinguishes_kind
        ; Alcotest.test_case
            "wire path: deployment pod template"
            `Quick
            test_workload_rows_of_payload_deployment
        ; Alcotest.test_case
            "wire path: cronjob pod template"
            `Quick
            test_workload_rows_of_payload_cronjob
        ; Alcotest.test_case
            "wire path: cronjob path is load-bearing"
            `Quick
            test_workload_rows_of_payload_cronjob_path
        ; Alcotest.test_case
            "wire path: workspace label is sanitized"
            `Quick
            test_workload_rows_of_payload_sanitizes_workspace
        ; Alcotest.test_case
            "a payload without items is an error"
            `Quick
            test_workload_rows_of_payload_requires_items
        ; Alcotest.test_case
            "Fn is reconstructed and verified as a CronJob, not skipped"
            `Quick
            test_fn_reconstructs_and_verifies_as_cronjob
        ; Alcotest.test_case
            "recreate strategy survives reconstruction"
            `Quick
            test_recreate_strategy_reconstructs
        ] )
    ; ( "pointer_report"
      , [ Alcotest.test_case "ok flag" `Quick test_pointer_report_ok
        ; Alcotest.test_case
            "names the canonical pointer ConfigMap"
            `Quick
            test_pointer_report_to_string_uses_canonical_name
        ] )
    ; ( "rollback_transaction"
      , [ Alcotest.test_case
            "unreadable applied state skips every mutation (BUG-078)"
            `Quick
            test_execute_applied_state_unavailable_skips_every_mutation
        ; Alcotest.test_case
            "lost ownership after apply skips prune and pointer (BUG-071)"
            `Quick
            test_execute_lost_ownership_after_apply_skips_prune_and_pointer
        ; Alcotest.test_case
            "lost ownership after prune skips pointer move (BUG-071)"
            `Quick
            test_execute_lost_ownership_after_prune_skips_pointer_move
        ; Alcotest.test_case
            "success calls every dep in order"
            `Quick
            test_execute_success_calls_every_dep_in_order
        ; Alcotest.test_case
            "apply-mode refusal calls no dep"
            `Quick
            test_execute_apply_mode_refusal_calls_no_deps
        ; Alcotest.test_case
            "migration boundary refusal calls no dep"
            `Quick
            test_execute_migration_boundary_refusal_calls_no_deps
        ; Alcotest.test_case
            "unexpected workload triggers prune then completes"
            `Quick
            test_execute_unexpected_workload_triggers_prune_then_completes
        ; Alcotest.test_case
            "prune failure skips pointer move"
            `Quick
            test_execute_prune_failure_skips_pointer_move
        ; Alcotest.test_case
            "missing workload skips prune and pointer move"
            `Quick
            test_execute_missing_workload_skips_prune_and_pointer_move
        ; Alcotest.test_case
            "mismatched workload skips prune and pointer move"
            `Quick
            test_execute_mismatched_workload_skips_prune_and_pointer_move
        ; Alcotest.test_case
            "the restored release's consumer groups are recorded last (BUG-090)"
            `Quick
            test_execute_records_the_restored_consumer_groups
        ; Alcotest.test_case
            "a failed verification leaves the guard record alone (BUG-090)"
            `Quick
            test_execute_leaves_the_guard_alone_when_verification_fails
        ; Alcotest.test_case
            "an uncorrected guard record is reported (BUG-090)"
            `Quick
            test_execute_reports_an_uncorrected_guard_record
        ] )
    ; ( "commit_release_selection"
      , [ Alcotest.test_case "commit_matches: exact" `Quick test_commit_matches_exact
        ; Alcotest.test_case
            "commit_matches: full resolves stored short"
            `Quick
            test_commit_matches_full_resolves_stored_short
        ; Alcotest.test_case
            "commit_matches: short resolves stored full"
            `Quick
            test_commit_matches_short_resolves_stored_full
        ; Alcotest.test_case
            "commit_matches: case insensitive"
            `Quick
            test_commit_matches_case_insensitive
        ; Alcotest.test_case
            "commit_matches: mismatch"
            `Quick
            test_commit_matches_mismatch
        ; Alcotest.test_case
            "commit_matches: empty never matches"
            `Quick
            test_commit_matches_empty_never_matches
        ; Alcotest.test_case "no match" `Quick test_resolve_commit_no_match_is_no_match
        ; Alcotest.test_case
            "unambiguous resolves"
            `Quick
            test_resolve_commit_unambiguous_resolves
        ; Alcotest.test_case
            "ambiguous lists candidates"
            `Quick
            test_resolve_commit_ambiguous_lists_candidates
        ; Alcotest.test_case
            "repeated deploys dedup"
            `Quick
            test_resolve_commit_repeated_deploys_dedup
        ; Alcotest.test_case
            "--scope narrows candidates"
            `Quick
            test_resolve_commit_scope_narrows_candidates
        ; Alcotest.test_case
            "wrong target excluded"
            `Quick
            test_resolve_commit_wrong_target_excluded
        ; Alcotest.test_case
            "Apply_failed excluded"
            `Quick
            test_resolve_commit_apply_failed_excluded
        ; Alcotest.test_case "invalid --scope" `Quick test_resolve_commit_invalid_scope
        ] )
    ]
;;
