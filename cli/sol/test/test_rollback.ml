let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let namespace ~workspace ~domain =
  Sol_cli_deployment_plan.namespace_of_exn ~workspace ~domain
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

(* ── FEAT-066 reconstruction gate ─────────────────────────────────────────
   A -> B -> C: decode correctness, identity correctness, render correctness.
   A fixture exercising rollout/canary, volumes + access modes, calls,
   called_by, ingress, config, secrets and namespace/name-derived URLs — the
   full manifest-affecting surface a release record must be able to restore. *)

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

(* billing_svc -> ledger_svc *)
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

(* ledger_svc's view of the same edge: called_by describes the CALLER
   (billing_svc), not a copy of the forward edge above -- this is exactly the
   FEAT-066 finding under test. *)
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
  ; replicas = 2
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
  ; replicas = 3
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

(* A: decode correctness -- field-by-field, so a failure names the divergent
   fact rather than "specs differ". *)
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
  | [ got_billing; got_ledger ] ->
    assert_spec_equal ~label:"billing_svc" billing_spec got_billing;
    assert_spec_equal ~label:"ledger_svc" ledger_spec got_ledger
  | specs -> Alcotest.failf "expected 2 reconstructed specs, got %d" (List.length specs)
;;

(* B: identity correctness -- reconstructed facts, run back through the same
   canonical projection, must rederive the record's own release_id. *)
let test_gate_b_identity_correctness () =
  let specs = reconstruct_ok () in
  let reconstructed_id =
    Sol_cli_release_id.of_content
      { workspace = gate_release.workspace
      ; environment = gate_release.environment
      ; workloads = List.map Sol_cli_deployment_plan.release_workload_of_spec specs
      }
  in
  Alcotest.(check string)
    "reconstructed release id matches the record"
    gate_release.release_id
    (Sol_cli_release_id.to_string reconstructed_id)
;;

(* C: render correctness -- plan -> render and record -> reconstruct -> render
   must produce byte-identical output per workload. Compare by (namespace,
   k8s_name) identity first so a missing/extra workload doesn't cascade into
   misleading per-line diffs. *)
let render_by_identity ~release_id specs =
  List.map
    (fun (s : Sol_cli_deployment_plan.service_spec) ->
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
    specs
  |> List.sort (fun (a, _) (b, _) -> compare a b)
;;

let test_gate_c_render_correctness () =
  let specs = reconstruct_ok () in
  let release_id =
    match Sol_cli_release_id.of_string gate_release.release_id with
    | Ok id -> id
    | Error msg -> Alcotest.fail msg
  in
  let original = render_by_identity ~release_id gate_plan.services in
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

(* Failure semantics: a semantically invalid recorded fact must fail closed in
   the domain decoder, before any render or mutation -- naming the release, the
   workload and the offending fact. *)
let bad_workload_release update : Sol_cli_release.t =
  { release_id = "r-0000000000000000"
  ; workspace = "myapp"
  ; environment = Some "prod"
  ; workloads = [ update (Sol_cli_deployment_plan.release_workload_of_spec ledger_spec) ]
  ; migrations = []
  ; apply_mode = Sol_cli_release.Direct
  }
;;

(* A failure here proves fail-closed lives in the domain decoder, not only in
   JSON parsing: the record is valid JSON and structurally parseable (it went
   through [release_workload_of_spec]), but semantically invalid. No render or
   mutation is possible on this path -- [service_specs_of_release] returning
   [Error] is the only way out. *)
let test_gate_failure_unknown_rollout_encoding () =
  let release =
    bad_workload_release (fun (w : Sol_cli_release.workload) ->
      { w with rollout = "canary:bogus" })
  in
  match Sol_cli_rollback.service_specs_of_release release with
  | Ok _ -> Alcotest.fail "expected reconstruction to fail on an unknown rollout encoding"
  | Error msg ->
    assert (contains (Str.regexp "r-0000000000000000") msg);
    assert (contains (Str.regexp "ledger_svc") msg);
    assert (contains (Str.regexp (Str.quote "canary:bogus")) msg)
;;

let test_gate_failure_invalid_cpu () =
  let release =
    bad_workload_release (fun (w : Sol_cli_release.workload) ->
      { w with cpu = "not-a-cpu-quantity" })
  in
  match Sol_cli_rollback.service_specs_of_release release with
  | Ok _ -> Alcotest.fail "expected reconstruction to fail on an invalid cpu quantity"
  | Error msg ->
    assert (contains (Str.regexp "ledger_svc") msg);
    assert (contains (Str.regexp (Str.quote "not-a-cpu-quantity")) msg)
;;

(* ── DEC-018 migration boundary check ─────────────────────────────────────── *)

let with_migrations_dir files f =
  let dir = Filename.temp_file "sol-migrations-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (name, _) -> Sys.remove (Filename.concat dir name)) files;
      Unix.rmdir dir)
    (fun () ->
       List.iter
         (fun (name, content) ->
            let oc = open_out (Filename.concat dir name) in
            output_string oc content;
            close_out oc)
         files;
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
       with
       | Ok () -> Alcotest.fail "expected a contracting migration to block the rollback"
       | Error (Sol_cli_rollback.Contracting_migration { release_id; migration }) ->
         Alcotest.(check string) "release_id" "r-1111111111111111" release_id;
         Alcotest.(check string) "migration" "0002_drop_col.sql" migration
       | Error (Sol_cli_rollback.Undeclared_disposition _ as e) ->
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
       with
       | Ok () ->
         Alcotest.fail "expected an undeclared disposition to block the rollback closed"
       | Error (Sol_cli_rollback.Undeclared_disposition { release_id; migration; reason })
         ->
         Alcotest.(check string) "release_id" "r-1111111111111111" release_id;
         Alcotest.(check string) "migration" "0002_mystery.sql" migration;
         assert (contains (Str.regexp "sol:disposition") reason)
       | Error (Sol_cli_rollback.Contracting_migration _ as e) ->
         Alcotest.failf
           "expected Undeclared_disposition, got: %s"
           (Sol_cli_rollback.migration_check_error_to_string e))
;;

(* An already-recorded contracting migration (present in release.migrations)
   never re-triggers the check -- only migrations *new since the release*
   matter, per the whole point of expand/contract discipline. *)
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
       with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Sol_cli_rollback.migration_check_error_to_string e))
;;

(* ── live_kind_of_service / live_resource_and_jsonpath ────────────────────
   Pure and deterministic -- no kubectl call -- so wrong here would make
   every verify call report a false workload mismatch, silently, the moment
   sol_cli_manifest_yaml.ml's label placement ever changed. Table-driven
   against every primitive/progressive_delivery combination so a renderer
   change that moves the `release` label has something to break. *)

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
  ; (* Fn ignores progressive_delivery entirely -- always a CronJob. *)
    ( "fn, canary (ignored)"
    , Sol_cli_deployment_plan.Fn
    , progressive_canary
    , Sol_cli_rollback.Live_cronjob )
  ]
;;

let test_live_kind_of_service_table () =
  List.iter
    (fun (label, primitive, progressive_delivery, expected) ->
       let spec = { ledger_spec with primitive; progressive_delivery } in
       let got = Sol_cli_rollback.live_kind_of_service spec in
       Alcotest.(check bool) label true (got = expected))
    live_kind_cases
;;

let live_kind_label = function
  | Sol_cli_rollback.Live_deployment -> "deployment"
  | Sol_cli_rollback.Live_rollout -> "rollout"
  | Sol_cli_rollback.Live_cronjob -> "cronjob"
;;

(* Cross-checked by hand against sol_cli_manifest_yaml.ml: deployment_doc and
   rollout_doc both put the `release` label at spec.template.metadata.labels
   (8-space indent, same as extra_labels); cronjob_doc nests one level deeper
   under spec.jobTemplate.spec.template.metadata.labels. If either renderer
   ever moves that label, this table must move with it. *)
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

(* ── apply_mode refusal ─────────────────────────────────────────────────────
   A GitOps/controller-owned release must never be rolled back by direct apply,
   so [check_apply_mode] refuses it before anything is touched. *)

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
  match Sol_cli_rollback.check_apply_mode ~release:verify_release with
  | Ok () -> ()
  | Error e -> Alcotest.fail (Sol_cli_rollback.apply_mode_check_error_to_string e)
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

(* ── workload set verification ──────────────────────────────────────────────
   Pure comparison of the restored release's expected workloads against the
   live set, plus the wire-path extraction of a listed object's pod-template
   labels. No cluster required. *)

let id kind namespace name : Sol_cli_rollback.workload_identity =
  { kind; namespace; name }
;;

let expected_specs = [ ledger_spec; billing_spec ]

(* ledger_spec is a Deployment at myapp-payments/ledger-svc; billing_spec is a
   Rollout (canary) at myapp-payments/billing-svc. *)
let ledger_id = id Sol_cli_rollback.Live_deployment "myapp-payments" "ledger-svc"
let billing_id = id Sol_cli_rollback.Live_rollout "myapp-payments" "billing-svc"

let test_verify_workloads_ok_when_set_matches () =
  let live =
    [ ledger_id, verify_release.release_id; billing_id, verify_release.release_id ]
  in
  let report =
    Sol_cli_rollback.verify_workloads
      ~release:verify_release
      ~expected:expected_specs
      ~live
  in
  Alcotest.(check bool)
    "workload set matches"
    true
    (Sol_cli_rollback.workload_report_ok report)
;;

(* The finding: a live workload the restored release does not contain (a
   service added between releases, left running) must be reported, not ignored. *)
let test_verify_workloads_reports_unexpected () =
  let stale_id = id Sol_cli_rollback.Live_deployment "myapp-payments" "fraud-svc" in
  let live =
    [ ledger_id, verify_release.release_id
    ; billing_id, verify_release.release_id
    ; stale_id, "r-9999999999999999"
    ]
  in
  let report =
    Sol_cli_rollback.verify_workloads
      ~release:verify_release
      ~expected:expected_specs
      ~live
  in
  Alcotest.(check bool) "not ok" false (Sol_cli_rollback.workload_report_ok report);
  let msg = Sol_cli_rollback.workload_report_to_string ~release:verify_release report in
  assert (contains (Str.regexp "unexpected workload") msg);
  assert (contains (Str.regexp "fraud-svc") msg)
;;

let test_verify_workloads_reports_missing () =
  let live = [ billing_id, verify_release.release_id ] in
  let report =
    Sol_cli_rollback.verify_workloads
      ~release:verify_release
      ~expected:expected_specs
      ~live
  in
  Alcotest.(check bool) "not ok" false (Sol_cli_rollback.workload_report_ok report);
  let msg = Sol_cli_rollback.workload_report_to_string ~release:verify_release report in
  assert (contains (Str.regexp "workload missing") msg);
  assert (contains (Str.regexp "ledger-svc") msg)
;;

let test_verify_workloads_reports_label_mismatch () =
  let live = [ ledger_id, "r-9999999999999999"; billing_id, verify_release.release_id ] in
  let report =
    Sol_cli_rollback.verify_workloads
      ~release:verify_release
      ~expected:expected_specs
      ~live
  in
  Alcotest.(check bool) "not ok" false (Sol_cli_rollback.workload_report_ok report);
  let msg = Sol_cli_rollback.workload_report_to_string ~release:verify_release report in
  assert (contains (Str.regexp "workload state mismatch") msg);
  assert (contains (Str.regexp "r-9999999999999999") msg)
;;

(* A release that switched a service from Deployment to Rollout keeps the
   namespace/name; the old object is a different identity and must be reported,
   not matched against the Rollout's label. *)
let test_verify_workloads_distinguishes_kind () =
  let ledger_as_rollout =
    id Sol_cli_rollback.Live_rollout "myapp-payments" "ledger-svc"
  in
  let live =
    [ ledger_as_rollout, verify_release.release_id
    ; billing_id, verify_release.release_id
    ]
  in
  let report =
    Sol_cli_rollback.verify_workloads
      ~release:verify_release
      ~expected:expected_specs
      ~live
  in
  Alcotest.(check bool) "not ok" false (Sol_cli_rollback.workload_report_ok report);
  let msg = Sol_cli_rollback.workload_report_to_string ~release:verify_release report in
  assert (contains (Str.regexp "workload missing") msg);
  assert (contains (Str.regexp "unexpected workload") msg)
;;

(* FEAT-072 premise check, pinned: Fn and recreate workloads are not skipped by
   rollback. FEAT-066 slice 2 replaced `kubectl rollout undo` with re-rendering
   and re-applying every reconstructed spec, so a CronJob is restored and
   verified like any other workload -- there is no native "previous revision"
   concept it lacks. This test is the regression guard for that claim. *)
let fn_spec : Sol_cli_deployment_plan.service_spec =
  { ledger_spec with
    source_name = "invoice_fn"
  ; k8s_name = k8s_name "invoice-fn"
  ; primitive = Sol_cli_deployment_plan.Fn
  ; schedule = Some "0 * * * *"
  ; replicas = 1
  ; rollout_strategy = None
  ; progressive_delivery = None
  }
;;

let fn_release : Sol_cli_release.t =
  { release_id = "r-3333333333333333"
  ; workspace = "myapp"
  ; environment = None
  ; workloads = [ Sol_cli_deployment_plan.release_workload_of_spec fn_spec ]
  ; migrations = []
  ; apply_mode = Sol_cli_release.Direct
  }
;;

let test_fn_reconstructs_and_verifies_as_cronjob () =
  match Sol_cli_rollback.service_specs_of_release fn_release with
  | Error msg -> Alcotest.fail msg
  | Ok [ got ] ->
    Alcotest.(check bool)
      "primitive is still Fn"
      true
      (got.Sol_cli_deployment_plan.primitive = Sol_cli_deployment_plan.Fn);
    Alcotest.(check (option string)) "schedule preserved" fn_spec.schedule got.schedule;
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
      Sol_cli_rollback.verify_workloads ~release:fn_release ~expected:[ got ] ~live
    in
    Alcotest.(check bool)
      "a CronJob is part of the verified set, not skipped"
      true
      (Sol_cli_rollback.workload_report_ok report)
  | Ok specs -> Alcotest.failf "expected 1 reconstructed spec, got %d" (List.length specs)
;;

(* The other half of the same premise: a `recreate` Deployment's strategy
   survives reconstruction (the gate's render equality covers the bytes; this
   names the fact). *)
let test_recreate_strategy_reconstructs () =
  let specs = reconstruct_ok () in
  let ledger =
    List.find
      (fun (s : Sol_cli_deployment_plan.service_spec) -> s.source_name = "ledger_svc")
      specs
  in
  Alcotest.(check bool)
    "recreate preserved"
    true
    (ledger.rollout_strategy = Some Sol_cli_toml.Recreate)
;;

(* The wire-path half: the pod-template label path [live_workloads] walks must
   agree with where the renderer puts the taxonomy labels. Two items, one
   workspace-matching and one not, plus one with no labels at all. *)
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
  in
  Alcotest.(check int) "only the workspace-matching item" 1 (List.length rows);
  let identity, release = List.hd rows in
  Alcotest.(check bool) "kind" true (identity.kind = Sol_cli_rollback.Live_deployment);
  Alcotest.(check string) "namespace" "myapp-payments" identity.namespace;
  Alcotest.(check string) "name" "ledger-svc" identity.name;
  Alcotest.(check string) "release label" "r-1" release
;;

(* A CronJob puts its pod template one level deeper; querying the Deployment
   payload as a CronJob must therefore find nothing -- the path is load-bearing. *)
let test_workload_rows_of_payload_cronjob_path () =
  let as_deployment =
    Sol_cli_rollback.workload_rows_of_payload
      ~kind:Sol_cli_rollback.Live_cronjob
      ~workspace:"myapp"
      deployment_payload
  in
  Alcotest.(check int)
    "deployment payload has no cronjob pod template"
    0
    (List.length as_deployment)
;;

(* The renderer writes `workspace` through sanitize_label_value, so the raw
   workspace passed to the lister must be matched the same way -- otherwise a
   mixed-case workspace matches nothing and every workload looks missing. *)
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
  in
  Alcotest.(check int) "one cronjob row" 1 (List.length rows);
  let identity, release = List.hd rows in
  Alcotest.(check string) "name" "invoice-fn" identity.name;
  Alcotest.(check string) "release label" "r-2" release
;;

(* ── pointer report ───────────────────────────────────────────────────────── *)

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

(* The message must name the ConfigMap as it actually is: the pointer name goes
   through the name sanitizer, so a raw workspace in the message is a bug. *)
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
    ]
;;
