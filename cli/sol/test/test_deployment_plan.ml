let check_string = Alcotest.(check string)

let contains re s =
  try
    ignore (Str.search_forward re s 0);
    true
  with
  | Not_found -> false
;;

let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let namespace ~workspace ~domain =
  Sol_cli_deployment_plan.namespace_of_exn ~workspace ~domain
;;

let namespace_string ~workspace ~domain =
  namespace ~workspace ~domain |> Sol_cli_deployment_plan.namespace_to_string
;;

(* ── plan_ids newtype helpers ───────────────────────────────────────────── *)

let topic_name_exn s =
  match Sol_cli_plan_ids.Topic_name.of_string s with
  | Ok t -> t
  | Error e -> Alcotest.fail (Printf.sprintf "invalid topic name %S: %s" s e)
;;

let migration_file_exn s =
  match Sol_cli_plan_ids.Migration_file.of_string s with
  | Ok t -> t
  | Error e -> Alcotest.fail (Printf.sprintf "invalid migration file %S: %s" s e)
;;

let schema_subject_exn s =
  match Sol_cli_plan_ids.Schema_subject.of_string s with
  | Ok t -> t
  | Error e -> Alcotest.fail (Printf.sprintf "invalid schema subject %S: %s" s e)
;;

let consumer_group_exn s =
  match Sol_cli_plan_ids.Consumer_group.of_string s with
  | Ok t -> t
  | Error e -> Alcotest.fail (Printf.sprintf "invalid consumer group %S: %s" s e)
;;

(** Compare a list of typed identifiers by their string representation. *)
let check_ids label stringify expected got =
  let expected_strs = List.map stringify expected in
  let got_strs = List.map stringify got in
  Alcotest.(check (list string)) label expected_strs got_strs
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

let test_k8s_name_underscores () =
  check_string
    "underscore to hyphen"
    "charge-svc"
    (Sol_cli_kubernetes_name.normalize "charge_svc")
;;

let test_k8s_name_worker () =
  check_string
    "worker suffix"
    "notify-worker"
    (Sol_cli_kubernetes_name.normalize "notify_worker")
;;

let test_k8s_name_no_underscores () =
  check_string
    "no underscores unchanged"
    "ordersvc"
    (Sol_cli_kubernetes_name.normalize "ordersvc")
;;

let test_namespace () =
  check_string
    "namespace format"
    "myapp-payments"
    (namespace_string ~workspace:"myapp" ~domain:"payments")
;;

let test_namespace_comms () =
  check_string
    "namespace comms domain"
    "pluto-comms"
    (namespace_string ~workspace:"pluto" ~domain:"comms")
;;

let test_namespace_sanitizes_workspace () =
  check_string
    "namespace sanitizes workspace"
    "comet-kafka-comms"
    (namespace_string ~workspace:"comet_kafka" ~domain:"comms")
;;

let test_namespace_uppercased_workspace () =
  check_string
    "uppercase workspace lowercased"
    "myapp-payments"
    (namespace_string ~workspace:"MyApp" ~domain:"payments")
;;

let test_k8s_name_rejects_invalid_characters () =
  match Sol_cli_deployment_plan.k8s_name_result "charge.svc" with
  | Error (Sol_cli_deployment_plan.Invalid_kubernetes_name { field; value; message }) ->
    check_string "field" "k8s_name" field;
    check_string "value" "charge.svc" value;
    assert (contains (Str.regexp "lowercase alphanumeric") message)
  | Ok _ -> Alcotest.fail "expected invalid k8s name"
  | Error (Sol_cli_deployment_plan.Toml_error _) -> Alcotest.fail "expected name error"
;;

let test_k8s_name_rejects_empty () =
  match Sol_cli_deployment_plan.k8s_name_result "" with
  | Error (Sol_cli_deployment_plan.Invalid_kubernetes_name { message; _ }) ->
    assert (contains (Str.regexp "1 and 63") message)
  | Ok _ -> Alcotest.fail "expected empty k8s name to fail"
  | Error (Sol_cli_deployment_plan.Toml_error _) -> Alcotest.fail "expected name error"
;;

let test_k8s_name_rejects_overlong () =
  let name = String.make 64 'a' in
  match Sol_cli_deployment_plan.k8s_name_result name with
  | Error (Sol_cli_deployment_plan.Invalid_kubernetes_name { value; message; _ }) ->
    check_string "value" name value;
    assert (contains (Str.regexp "1 and 63") message)
  | Ok _ -> Alcotest.fail "expected overlong k8s name to fail"
  | Error (Sol_cli_deployment_plan.Toml_error _) -> Alcotest.fail "expected name error"
;;

let test_namespace_rejects_invalid_domain () =
  match
    Sol_cli_deployment_plan.namespace_result ~workspace:"myapp" ~domain:"payments.api"
  with
  | Error (Sol_cli_deployment_plan.Invalid_kubernetes_name { field; value; message }) ->
    check_string "field" "namespace" field;
    check_string "value" "myapp-payments.api" value;
    assert (contains (Str.regexp "lowercase alphanumeric") message)
  | Ok _ -> Alcotest.fail "expected invalid namespace"
  | Error (Sol_cli_deployment_plan.Toml_error _) -> Alcotest.fail "expected name error"
;;

let test_namespace_rejects_overlong () =
  match
    Sol_cli_deployment_plan.namespace_result
      ~workspace:(String.make 40 'a')
      ~domain:(String.make 30 'b')
  with
  | Error (Sol_cli_deployment_plan.Invalid_kubernetes_name { field; message; _ }) ->
    check_string "field" "namespace" field;
    assert (contains (Str.regexp "1 and 63") message)
  | Ok _ -> Alcotest.fail "expected overlong namespace"
  | Error (Sol_cli_deployment_plan.Toml_error _) -> Alcotest.fail "expected name error"
;;

let test_image_ref_local () =
  check_string
    "local k3d image ref"
    "sol-registry:5000/myapp/charge-svc:abc123"
    (Sol_cli_deployment_plan.image_ref
       ~registry:"sol-registry:5000"
       ~workspace:"myapp"
       ~k8s_name:(k8s_name "charge-svc")
       ~tag:"abc123")
;;

let test_image_ref_ecr () =
  check_string
    "ECR image ref"
    "123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/charge-svc:sha-deadbeef"
    (Sol_cli_deployment_plan.image_ref
       ~registry:"123456789.dkr.ecr.us-east-1.amazonaws.com"
       ~workspace:"myapp"
       ~k8s_name:(k8s_name "charge-svc")
       ~tag:"sha-deadbeef")
;;

let test_image_ref_push_registry () =
  check_string
    "localhost push registry"
    "localhost:5000/myapp/charge-svc:dev"
    (Sol_cli_deployment_plan.image_ref
       ~registry:"localhost:5000"
       ~workspace:"myapp"
       ~k8s_name:(k8s_name "charge-svc")
       ~tag:"dev")
;;

(* ── to_json tests ─────────────────────────────────────────────────────── *)

(** Build a small but complete plan for use across serialization tests. *)
let sample_plan () : Sol_cli_deployment_plan.t =
  let env : Sol_cli_deployment_plan.env_config =
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
  in
  let svc : Sol_cli_deployment_plan.service_spec =
    { domain = "orders"
    ; source_name = "charge_svc"
    ; k8s_name = k8s_name "charge-svc"
    ; namespace = namespace ~workspace:"myworkspace" ~domain:"orders"
    ; primitive = Sol_cli_deployment_plan.Svc
    ; source_dir = "/tmp/app/orders/charge_svc"
    ; image = "123.dkr.ecr.us-east-1.amazonaws.com/myworkspace/charge-svc:abc1234"
    ; config = [ "LOG_LEVEL", "info"; "REGION", "us-east-1" ]
    ; secrets = [ "DB_PASSWORD", "super-secret-value"; "API_KEY", "also-secret" ]
    ; volumes = []
    ; schedule = None
    ; replicas = 2
    ; cpu = cpu "250m"
    ; memory = memory "256Mi"
    ; rollout_strategy = None
    ; ingress_host = None
    ; ingress_path = None
    ; cluster_issuer = "letsencrypt-prod"
    ; extra_labels = []
    ; progressive_delivery = None
    }
  in
  { workspace = "myworkspace"
  ; environment = env
  ; services = [ svc ]
  ; topics = [ topic_name_exn "sol-demo-orders" ]
  ; migrations = []
  ; schema_subjects = []
  ; consumer_groups = []
  }
;;

let test_to_json_valid_json () =
  let plan = sample_plan () in
  let json = Sol_cli_deployment_plan.to_json plan in
  let s = Yojson.Safe.to_string json in
  (* round-trip: must parse without raising *)
  let _ = Yojson.Safe.from_string s in
  ()
;;

let test_to_json_deterministic () =
  let plan = sample_plan () in
  let s1 = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  let s2 = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  Alcotest.(check string) "byte-identical" s1 s2
;;

let test_to_json_no_secret_values () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  (* Neither secret value must appear in the output *)
  if
    String.length (Str.global_replace (Str.regexp "super-secret-value") "" s)
    < String.length s
  then Alcotest.fail "secret value 'super-secret-value' leaked into plan JSON";
  if String.length (Str.global_replace (Str.regexp "also-secret") "" s) < String.length s
  then Alcotest.fail "secret value 'also-secret' leaked into plan JSON"
;;

(* FEAT-026: sample_plan's environment.env = Some "prod" must reach
   --emit-plan-to's JSON output, same as region/base_domain already did. *)
let test_to_json_env_present () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp {|"env":"prod"|} in
    contains re s)
;;

let test_to_json_secret_keys_present () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  (* Secret keys must appear *)
  assert (
    let re = Str.regexp "DB_PASSWORD" in
    contains re s);
  assert (
    let re = Str.regexp "API_KEY" in
    contains re s)
;;

let test_to_json_config_values_present () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  (* Config values (not secrets) must appear in full *)
  assert (
    let re = Str.regexp "us-east-1" in
    contains re s)
;;

let test_to_json_mode_strings () =
  let check_mode mode expected =
    let env : Sol_cli_deployment_plan.env_config =
      { name = "env"
      ; mode
      ; registry = "r"
      ; image_tag = "t"
      ; env = None
      ; region = None
      ; base_domain = None
      ; cluster_issuer = "letsencrypt-prod"
      ; secret_backend = Sol_cli_manifest.Kubernetes_placeholder
      }
    in
    let plan : Sol_cli_deployment_plan.t =
      { workspace = "ws"
      ; environment = env
      ; services = []
      ; topics = []
      ; migrations = []
      ; schema_subjects = []
      ; consumer_groups = []
      }
    in
    let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
    assert (
      let re = Str.regexp (Printf.sprintf {|"mode":"%s"|} expected) in
      contains re s)
  in
  check_mode Sol_cli_deployment_plan.Local "local";
  check_mode Sol_cli_deployment_plan.Customer_cloud "customer_cloud";
  check_mode Sol_cli_deployment_plan.Sol_hosted "sol_hosted"
;;

(* ── discover_topics / discover_migrations tests ────────────────────────── *)

(** Run [f ()] with cwd temporarily changed to [dir]. *)
let with_cwd dir f =
  let orig = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect f ~finally:(fun () -> Sys.chdir orig)
;;

(** Create a directory (and intermediate parents) if it does not already exist.
*)
let mkdirs path =
  let parts = String.split_on_char '/' path in
  let _ =
    List.fold_left
      (fun acc part ->
         let p = if acc = "" then part else acc ^ "/" ^ part in
         if p <> "" && not (Sys.file_exists p) then Unix.mkdir p 0o755;
         p)
      ""
      parts
  in
  ()
;;

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let test_discover_topics_finds_topic () =
  let tmp = Filename.temp_dir "sol_test_topics" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    write_file
      "events/payments/sol.toml"
      {|[service]
topics = ["payments.charged"]
|};
    let topics = Sol_cli_deployment_plan.discover_topics () in
    check_ids
      "topic found"
      Sol_cli_plan_ids.Topic_name.to_string
      [ topic_name_exn "payments.charged" ]
      topics)
;;

let test_discover_topics_empty_when_no_dir () =
  let tmp = Filename.temp_dir "sol_test_topics_nodir" "" in
  with_cwd tmp (fun () ->
    let topics = Sol_cli_deployment_plan.discover_topics () in
    Alcotest.(check int) "empty without events dir" 0 (List.length topics))
;;

let test_discover_topics_multiple_topics_in_toml () =
  let tmp = Filename.temp_dir "sol_test_topics_multi" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    write_file
      "events/payments/sol.toml"
      {|[service]
topics = ["payments.charged", "payments.refunded"]
|};
    let topics = Sol_cli_deployment_plan.discover_topics () in
    check_ids
      "multiple topics in one toml"
      Sol_cli_plan_ids.Topic_name.to_string
      [ topic_name_exn "payments.charged"; topic_name_exn "payments.refunded" ]
      topics)
;;

let test_discover_topics_deduplicates () =
  let tmp = Filename.temp_dir "sol_test_topics_dedup" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/a";
    mkdirs "events/b";
    (* Same topic listed in two different event sol.toml files *)
    write_file
      "events/a/sol.toml"
      {|[service]
topics = ["dup.topic"]
|};
    write_file
      "events/b/sol.toml"
      {|[service]
topics = ["dup.topic"]
|};
    let topics = Sol_cli_deployment_plan.discover_topics () in
    check_ids
      "deduplicates"
      Sol_cli_plan_ids.Topic_name.to_string
      [ topic_name_exn "dup.topic" ]
      topics)
;;

let test_discover_topics_subdirectory () =
  let tmp = Filename.temp_dir "sol_test_topics_subdir" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    write_file
      "events/payments/sol.toml"
      {|[service]
topics = ["payments.charged"]
|};
    let topics = Sol_cli_deployment_plan.discover_topics () in
    check_ids
      "subdirectory topic found"
      Sol_cli_plan_ids.Topic_name.to_string
      [ topic_name_exn "payments.charged" ]
      topics)
;;

let test_discover_topics_top_level_toml () =
  let tmp = Filename.temp_dir "sol_test_topics_toplevel" "" in
  with_cwd tmp (fun () ->
    mkdirs "events";
    write_file
      "events/sol.toml"
      {|[service]
topics = ["top.event"]
|};
    let topics = Sol_cli_deployment_plan.discover_topics () in
    check_ids
      "top-level events/sol.toml"
      Sol_cli_plan_ids.Topic_name.to_string
      [ topic_name_exn "top.event" ]
      topics)
;;

let test_discover_topics_mixed_levels () =
  let tmp = Filename.temp_dir "sol_test_topics_mixed" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    mkdirs "events/orders";
    write_file
      "events/sol.toml"
      {|[service]
topics = ["top.event"]
|};
    write_file
      "events/payments/sol.toml"
      {|[service]
topics = ["payments.charged"]
|};
    write_file
      "events/orders/sol.toml"
      {|[service]
topics = ["orders.placed"]
|};
    let topics = Sol_cli_deployment_plan.discover_topics () in
    check_ids
      "mixed top-level and subdir topics"
      Sol_cli_plan_ids.Topic_name.to_string
      [ topic_name_exn "orders.placed"
      ; topic_name_exn "payments.charged"
      ; topic_name_exn "top.event"
      ]
      topics)
;;

(** Comments and unrelated strings in .ml files must NOT create false positives,
    because discover_topics no longer scans .ml source files at all. *)
let test_discover_topics_no_false_positives_from_ml_files () =
  let tmp = Filename.temp_dir "sol_test_topics_fp" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    (* Write .ml files with topic_name patterns — these must be ignored *)
    write_file
      "events/payments/charged.ml"
      "(* let topic_name = \"commented.out.topic\" *)\n\
       let topic_name = Kafka_service.topic_name_exn \"payments.charged\"\n\
       let s = \"let topic_name = not-a-real-topic\"\n";
    (* No sol.toml — so discover_topics should return [] *)
    let topics = Sol_cli_deployment_plan.discover_topics () in
    Alcotest.(check int)
      "ml files are not scanned — no false positives from comments or strings"
      0
      (List.length topics))
;;

(* ── extract_schedule tests ─────────────────────────────────────────────── *)

let test_extract_schedule_reads_from_sol_toml () =
  let tmp = Filename.temp_dir "sol_test_sched" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/cron/report_fn";
    write_file
      "app/cron/report_fn/sol.toml"
      {|[service]
schedule = "30 6 * * 1"
|};
    let schedule =
      Sol_cli_manifest.extract_schedule ~dir:"app/cron/report_fn" ~name:"report_fn"
    in
    Alcotest.(check string) "schedule from sol.toml" "30 6 * * 1" schedule)
;;

let test_extract_schedule_defaults_when_no_toml () =
  let tmp = Filename.temp_dir "sol_test_sched_default" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/cron/report_fn";
    (* No sol.toml — default hourly schedule *)
    let schedule =
      Sol_cli_manifest.extract_schedule ~dir:"app/cron/report_fn" ~name:"report_fn"
    in
    Alcotest.(check string) "default schedule" "0 * * * *" schedule)
;;

let test_extract_schedule_defaults_when_no_schedule_key () =
  let tmp = Filename.temp_dir "sol_test_sched_nokey" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/cron/report_fn";
    write_file
      "app/cron/report_fn/sol.toml"
      {|[infra.scale]
replicas = 1
|};
    (* sol.toml exists but has no [service] schedule *)
    let schedule =
      Sol_cli_manifest.extract_schedule ~dir:"app/cron/report_fn" ~name:"report_fn"
    in
    Alcotest.(check string) "default when no schedule key" "0 * * * *" schedule)
;;

let test_extract_schedule_ignores_ml_source_pattern () =
  let tmp = Filename.temp_dir "sol_test_sched_ml" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/cron/report_fn/lib";
    (* Write an ML file with the old schedule pattern — must be ignored *)
    write_file
      "app/cron/report_fn/lib/report_fn.ml"
      {|let schedule = "0 3 * * *"
let run () = Ok ()
|};
    (* No sol.toml — so we get the default, not the ml-file value *)
    let schedule =
      Sol_cli_manifest.extract_schedule ~dir:"app/cron/report_fn" ~name:"report_fn"
    in
    Alcotest.(check string)
      "ml source not scanned — default returned"
      "0 * * * *"
      schedule)
;;

let test_discover_migrations_finds_sql () =
  let tmp = Filename.temp_dir "sol_test_mig" "" in
  with_cwd tmp (fun () ->
    mkdirs "db/migrations";
    write_file "db/migrations/001_init.sql" "CREATE TABLE foo (id INT);";
    let migs = Sol_cli_deployment_plan.discover_migrations () in
    check_ids
      "migration found"
      Sol_cli_plan_ids.Migration_file.to_string
      [ migration_file_exn "001_init.sql" ]
      migs)
;;

let test_discover_migrations_empty_when_no_dir () =
  let tmp = Filename.temp_dir "sol_test_mig_nodir" "" in
  with_cwd tmp (fun () ->
    let migs = Sol_cli_deployment_plan.discover_migrations () in
    Alcotest.(check int) "empty without db/migrations dir" 0 (List.length migs))
;;

let test_discover_migrations_sorted () =
  let tmp = Filename.temp_dir "sol_test_mig_sorted" "" in
  with_cwd tmp (fun () ->
    mkdirs "db/migrations";
    write_file "db/migrations/003_add_index.sql" "";
    write_file "db/migrations/001_init.sql" "";
    write_file "db/migrations/002_add_col.sql" "";
    let migs = Sol_cli_deployment_plan.discover_migrations () in
    check_ids
      "migrations sorted"
      Sol_cli_plan_ids.Migration_file.to_string
      [ migration_file_exn "001_init.sql"
      ; migration_file_exn "002_add_col.sql"
      ; migration_file_exn "003_add_index.sql"
      ]
      migs)
;;

let test_discover_migrations_ignores_non_sql () =
  let tmp = Filename.temp_dir "sol_test_mig_nosql" "" in
  with_cwd tmp (fun () ->
    mkdirs "db/migrations";
    write_file "db/migrations/001_init.sql" "";
    write_file "db/migrations/README.md" "";
    write_file "db/migrations/seed.sh" "";
    let migs = Sol_cli_deployment_plan.discover_migrations () in
    check_ids
      "only sql files"
      Sol_cli_plan_ids.Migration_file.to_string
      [ migration_file_exn "001_init.sql" ]
      migs)
;;

(* ── schema_subjects tests ──────────────────────────────────────────────── *)

let test_schema_subjects_derived () =
  let tmp = Filename.temp_dir "sol_test_subjects" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    write_file "events/payments/charged.ml" "(* stub *)";
    let subjects = Sol_cli_deployment_plan.discover_schema_subjects () in
    let strs = List.map Sol_cli_plan_ids.Schema_subject.to_string subjects in
    Alcotest.(check bool)
      "payments.Charged present"
      true
      (List.mem "payments.Charged" strs))
;;

let test_schema_subjects_multiple_domains () =
  let tmp = Filename.temp_dir "sol_test_subjects_multi" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    mkdirs "events/comms";
    write_file "events/payments/charged.ml" "(* stub *)";
    write_file "events/comms/notification.ml" "(* stub *)";
    let subjects = Sol_cli_deployment_plan.discover_schema_subjects () in
    check_ids
      "sorted multi-domain"
      Sol_cli_plan_ids.Schema_subject.to_string
      [ schema_subject_exn "comms.Notification"; schema_subject_exn "payments.Charged" ]
      subjects)
;;

let test_schema_subjects_top_level_ml () =
  let tmp = Filename.temp_dir "sol_test_subjects_top" "" in
  with_cwd tmp (fun () ->
    mkdirs "events";
    write_file "events/order.ml" "(* stub *)";
    let subjects = Sol_cli_deployment_plan.discover_schema_subjects () in
    let strs = List.map Sol_cli_plan_ids.Schema_subject.to_string subjects in
    Alcotest.(check bool) "top-level file as stem" true (List.mem "order" strs))
;;

let test_schema_subjects_empty_when_no_dir () =
  let tmp = Filename.temp_dir "sol_test_subjects_nodir" "" in
  with_cwd tmp (fun () ->
    let subjects = Sol_cli_deployment_plan.discover_schema_subjects () in
    Alcotest.(check int) "empty without events dir" 0 (List.length subjects))
;;

(* ── consumer_groups tests ──────────────────────────────────────────────── *)

let make_worker_spec name domain =
  { Sol_cli_deployment_plan.domain
  ; source_name = name
  ; k8s_name = k8s_name name
  ; namespace = namespace ~workspace:"ws" ~domain
  ; primitive = Sol_cli_deployment_plan.Worker
  ; source_dir = domain ^ "/" ^ name
  ; image = "reg/ws/" ^ name ^ ":t"
  ; config = []
  ; secrets = []
  ; volumes = []
  ; schedule = None
  ; replicas = 1
  ; cpu = cpu "100m"
  ; memory = memory "128Mi"
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; extra_labels = []
  ; progressive_delivery = None
  }
;;

let make_svc_spec name domain =
  { (make_worker_spec name domain) with primitive = Sol_cli_deployment_plan.Svc }
;;

let test_consumer_groups_derived () =
  let worker = make_worker_spec "notify_worker" "comms" in
  let groups = Sol_cli_deployment_plan.derive_consumer_groups "myworkspace" [ worker ] in
  check_ids
    "worker produces consumer group"
    Sol_cli_plan_ids.Consumer_group.to_string
    [ consumer_group_exn "myworkspace.comms.notify_worker" ]
    groups
;;

let test_consumer_groups_excludes_svc () =
  let worker = make_worker_spec "notify_worker" "comms" in
  let svc = make_svc_spec "charge_svc" "payments" in
  let groups = Sol_cli_deployment_plan.derive_consumer_groups "ws" [ worker; svc ] in
  Alcotest.(check int) "only one group (worker only)" 1 (List.length groups)
;;

let test_consumer_groups_sorted () =
  let w1 = make_worker_spec "b_worker" "comms" in
  let w2 = make_worker_spec "a_worker" "comms" in
  let groups = Sol_cli_deployment_plan.derive_consumer_groups "ws" [ w1; w2 ] in
  check_ids
    "consumer groups sorted"
    Sol_cli_plan_ids.Consumer_group.to_string
    [ consumer_group_exn "ws.comms.a_worker"; consumer_group_exn "ws.comms.b_worker" ]
    groups
;;

(* ── to_json v2 field tests ─────────────────────────────────────────────── *)

let test_to_json_secret_backend () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp {|"secret_backend"|} in
    contains re s)
;;

let test_to_json_secret_backend_values () =
  let check_backend backend expected =
    let plan = sample_plan () in
    let plan =
      { plan with environment = { plan.environment with secret_backend = backend } }
    in
    let json = Sol_cli_deployment_plan.to_json plan in
    let actual =
      Yojson.Safe.Util.(
        json |> member "environment" |> member "secret_backend" |> to_string)
    in
    Alcotest.(check string) expected expected actual
  in
  check_backend Sol_cli_manifest.Kubernetes_live "kubernetes-live";
  check_backend Sol_cli_manifest.Kubernetes_placeholder "kubernetes-placeholder";
  check_backend
    (Sol_cli_manifest.External_secrets
       { store_ref = "cluster-secret-store"
       ; store_kind = "ClusterSecretStore"
       ; key_prefix = "prod/myworkspace"
       ; refresh_interval = "1h"
       })
    "external-secrets"
;;

let test_to_json_rollout_strategy () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp {|"rollout_strategy":"rolling_update"|} in
    contains re s)
;;

let test_to_json_rollout_strategy_recreate () =
  let plan = sample_plan () in
  let svc_recreate =
    { (List.hd plan.services) with rollout_strategy = Some Sol_cli_toml.Recreate }
  in
  let plan2 = { plan with services = [ svc_recreate ] } in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan2) in
  assert (
    let re = Str.regexp {|"rollout_strategy":"recreate"|} in
    contains re s)
;;

let test_to_json_rollout_strategy_canary () =
  let plan = sample_plan () in
  let svc_canary =
    { (List.hd plan.services) with
      progressive_delivery = Some (Sol_cli_toml.Canary { steps = [] })
    }
  in
  let plan2 = { plan with services = [ svc_canary ] } in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan2) in
  assert (
    let re = Str.regexp {|"rollout_strategy":"canary"|} in
    contains re s)
;;

let test_to_json_rollout_strategy_blue_green () =
  let plan = sample_plan () in
  let svc_bg =
    { (List.hd plan.services) with progressive_delivery = Some Sol_cli_toml.Blue_green }
  in
  let plan2 = { plan with services = [ svc_bg ] } in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan2) in
  assert (
    let re = Str.regexp {|"rollout_strategy":"blue_green"|} in
    contains re s)
;;

let check_effective_rollout_strategy label expected svc =
  let strategy =
    svc
    |> Sol_cli_deployment_plan.effective_rollout_strategy
    |> Sol_cli_deployment_plan.effective_rollout_strategy_to_string
  in
  check_string label expected strategy
;;

let test_effective_rollout_strategy_defaults_to_rolling_update () =
  let svc = List.hd (sample_plan ()).services in
  check_effective_rollout_strategy "default" "rolling_update" svc
;;

let test_effective_rollout_strategy_recreate () =
  let svc =
    { (List.hd (sample_plan ()).services) with
      rollout_strategy = Some Sol_cli_toml.Recreate
    }
  in
  check_effective_rollout_strategy "recreate" "recreate" svc
;;

let test_effective_rollout_strategy_progressive_delivery_precedence () =
  let svc =
    { (List.hd (sample_plan ()).services) with
      rollout_strategy = Some Sol_cli_toml.Recreate
    ; progressive_delivery = Some Sol_cli_toml.Blue_green
    }
  in
  check_effective_rollout_strategy "progressive precedence" "blue_green" svc
;;

let test_summary_uses_effective_rollout_strategy () =
  let plan = sample_plan () in
  let svc =
    { (List.hd plan.services) with
      progressive_delivery = Some (Sol_cli_toml.Canary { steps = [] })
    }
  in
  let plan = { plan with services = [ svc ] } in
  let summary = Format.asprintf "%a" Sol_cli_deployment_plan.pp_summary plan in
  assert (
    let re = Str.regexp {|rollout=canary|} in
    contains re summary)
;;

let test_to_json_ingress_null_when_absent () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp {|"ingress":null|} in
    contains re s)
;;

let test_to_json_ingress_present () =
  let plan = sample_plan () in
  let svc_with_ingress =
    { (List.hd plan.services) with
      ingress_host = Some (hostname "example.com")
    ; ingress_path = Some (ingress_path "/api")
    }
  in
  let plan2 = { plan with services = [ svc_with_ingress ] } in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan2) in
  List.iter
    (fun fragment -> assert (contains (Str.regexp_string fragment) s))
    [ {|"ingress":{"host":"example.com","path":"/api"|}
    ; {|"tls":{"hosts":["example.com"],"secretName":"charge-svc-tls"}|}
    ; {|"cluster_issuer":"letsencrypt-prod"|}
    ; {|"cert-manager.io/cluster-issuer":"letsencrypt-prod"|}
    ; {|"nginx.ingress.kubernetes.io/ssl-redirect":"true"|}
    ]
;;

let test_to_json_schema_subjects_present () =
  let plan =
    { (sample_plan ()) with
      schema_subjects =
        [ schema_subject_exn "payments.Charged"; schema_subject_exn "comms.Notification" ]
    }
  in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp {|"schema_subjects"|} in
    contains re s);
  assert (
    let re = Str.regexp "payments.Charged" in
    contains re s)
;;

let test_to_json_consumer_groups_present () =
  let plan =
    { (sample_plan ()) with
      consumer_groups = [ consumer_group_exn "myworkspace.comms.notify_worker" ]
    }
  in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp {|"consumer_groups"|} in
    contains re s);
  assert (
    let re = Str.regexp "myworkspace.comms.notify_worker" in
    contains re s)
;;

let test_of_services_result_surfaces_toml_parse_error () =
  let tmp = Filename.temp_dir "sol_test_plan_toml_error" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file
      "app/payments/charge_svc/sol.toml"
      "[infra.deploy]\nrollout_strategy = \"Blue/Green\"\n";
    let env : Sol_cli_deployment_plan.env_config =
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
    in
    let service : Sol_cli_manifest.service =
      { domain = "payments"
      ; name = "charge_svc"
      ; primitive = Sol_cli_manifest.Svc
      ; dir = "app/payments/charge_svc"
      }
    in
    match
      Sol_cli_deployment_plan.of_services_result ~workspace:"myworkspace" ~env [ service ]
    with
    | Error
        (Sol_cli_deployment_plan.Toml_error (Sol_cli_toml.Validation { path; message }))
      ->
      Alcotest.(check string) "error path" "app/payments/charge_svc/sol.toml" path;
      assert (contains (Str.regexp "unsupported rollout_strategy") message)
    | Ok _ -> Alcotest.fail "expected deployment-plan construction to return TOML error"
    | Error (Sol_cli_deployment_plan.Toml_error (Sol_cli_toml.Toml_syntax _)) ->
      Alcotest.fail "expected validation error, got syntax error"
    | Error (Sol_cli_deployment_plan.Invalid_kubernetes_name _) ->
      Alcotest.fail "expected TOML error, got Kubernetes name error")
;;

(* ── BUG-004: sol.yml scale overrides sol.toml replicas ──────────────────── *)

let deploy_env : Sol_cli_deployment_plan.env_config =
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

let charge_svc_service : Sol_cli_manifest.service =
  { domain = "payments"
  ; name = "charge_svc"
  ; primitive = Sol_cli_manifest.Svc
  ; dir = "app/payments/charge_svc"
  }
;;

let resolved_config_with_scale ~name ~scale_min ~scale_max : Sol_cli_config.t =
  { project = None
  ; target = None
  ; resources = []
  ; services =
      [ { name; typ = None; path = None; uses = []; scale_min; scale_max; omit = false } ]
  }
;;

let replicas_of_sole_service plan =
  match plan.Sol_cli_deployment_plan.services with
  | [ s ] -> s.Sol_cli_deployment_plan.replicas
  | _ -> Alcotest.fail "expected exactly one service in plan"
;;

let test_sol_yml_scale_overrides_toml_replicas_on_resolved_target () =
  let tmp = Filename.temp_dir "sol_test_plan_scale_override" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file "app/payments/charge_svc/sol.toml" "[infra.scale]\nreplicas = 2\n";
    let resolved_config =
      resolved_config_with_scale ~name:"charge_svc" ~scale_min:None ~scale_max:(Some 5)
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~workspace:"myworkspace"
        ~env:deploy_env
        ~resolved_config
        [ charge_svc_service ]
    with
    | Ok plan ->
      Alcotest.(check int) "sol.yml scale_max wins" 5 (replicas_of_sole_service plan)
    | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let test_sol_yml_scale_falls_back_to_scale_min_when_no_max () =
  let tmp = Filename.temp_dir "sol_test_plan_scale_min" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file "app/payments/charge_svc/sol.toml" "[infra.scale]\nreplicas = 2\n";
    let resolved_config =
      resolved_config_with_scale ~name:"charge_svc" ~scale_min:(Some 3) ~scale_max:None
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~workspace:"myworkspace"
        ~env:deploy_env
        ~resolved_config
        [ charge_svc_service ]
    with
    | Ok plan ->
      Alcotest.(check int)
        "sol.yml scale_min used when no scale_max"
        3
        (replicas_of_sole_service plan)
    | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let test_no_resolved_config_uses_toml_replicas () =
  let tmp = Filename.temp_dir "sol_test_plan_no_resolved_config" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file "app/payments/charge_svc/sol.toml" "[infra.scale]\nreplicas = 2\n";
    (* Simulates `sol up`, which never has a resolved target/sol.yml. *)
    match
      Sol_cli_deployment_plan.of_services_result
        ~workspace:"myworkspace"
        ~env:deploy_env
        [ charge_svc_service ]
    with
    | Ok plan ->
      Alcotest.(check int) "sol.toml replicas unchanged" 2 (replicas_of_sole_service plan)
    | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let test_no_matching_sol_yml_service_uses_toml_replicas () =
  let tmp = Filename.temp_dir "sol_test_plan_no_matching_service" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file "app/payments/charge_svc/sol.toml" "[infra.scale]\nreplicas = 2\n";
    let resolved_config =
      resolved_config_with_scale ~name:"other_svc" ~scale_min:None ~scale_max:(Some 9)
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~workspace:"myworkspace"
        ~env:deploy_env
        ~resolved_config
        [ charge_svc_service ]
    with
    | Ok plan ->
      Alcotest.(check int)
        "no matching sol.yml service falls back to sol.toml"
        2
        (replicas_of_sole_service plan)
    | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let test_toml_volumes_carry_into_service_spec () =
  let tmp = Filename.temp_dir "sol_test_plan_volumes" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file
      "app/payments/charge_svc/sol.toml"
      "[infra.volumes.data]\n\
       mount_path = \"/var/lib/data\"\n\
       size = \"10Gi\"\n\
       access_mode = \"ReadWriteOnce\"\n";
    match
      Sol_cli_deployment_plan.of_services_result
        ~workspace:"myworkspace"
        ~env:deploy_env
        [ charge_svc_service ]
    with
    | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)
    | Ok plan ->
      (match plan.Sol_cli_deployment_plan.services with
       | [ spec ] ->
         (match spec.Sol_cli_deployment_plan.volumes with
          | [ volume ] ->
            Alcotest.(check string) "volume name" "data" volume.Sol_cli_toml.name;
            Alcotest.(check string)
              "mount path"
              "/var/lib/data"
              volume.Sol_cli_toml.mount_path;
            Alcotest.(check string) "size" "10Gi" volume.Sol_cli_toml.size;
            Alcotest.(check bool)
              "access mode"
              true
              (volume.Sol_cli_toml.access_mode = Sol_cli_toml.ReadWriteOnce)
          | _ -> Alcotest.fail "expected exactly one volume")
       | _ -> Alcotest.fail "expected exactly one service"))
;;

(* ── plan_ids newtype unit tests ────────────────────────────────────────── *)

let test_topic_name_valid () =
  match Sol_cli_plan_ids.Topic_name.of_string "payments.charged" with
  | Ok t ->
    check_string
      "round-trips"
      "payments.charged"
      (Sol_cli_plan_ids.Topic_name.to_string t)
  | Error e -> Alcotest.fail e
;;

let test_topic_name_empty_fails () =
  match Sol_cli_plan_ids.Topic_name.of_string "" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected empty topic name to fail"
;;

let test_topic_name_too_long_fails () =
  let s = String.make 250 'a' in
  match Sol_cli_plan_ids.Topic_name.of_string s with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected overlong topic name to fail"
;;

let test_topic_name_invalid_char_fails () =
  match Sol_cli_plan_ids.Topic_name.of_string "bad name!" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected topic name with space/bang to fail"
;;

let test_topic_name_max_length_ok () =
  let s = String.make 249 'a' in
  match Sol_cli_plan_ids.Topic_name.of_string s with
  | Ok _ -> ()
  | Error e -> Alcotest.fail e
;;

let test_migration_file_valid () =
  match Sol_cli_plan_ids.Migration_file.of_string "001_init.sql" with
  | Ok t ->
    check_string
      "round-trips"
      "001_init.sql"
      (Sol_cli_plan_ids.Migration_file.to_string t)
  | Error e -> Alcotest.fail e
;;

let test_migration_file_empty_fails () =
  match Sol_cli_plan_ids.Migration_file.of_string "" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected empty migration file to fail"
;;

let test_migration_file_not_sql_fails () =
  match Sol_cli_plan_ids.Migration_file.of_string "001_init.sh" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected non-.sql migration file to fail"
;;

let test_schema_subject_valid () =
  match Sol_cli_plan_ids.Schema_subject.of_string "payments.Charged" with
  | Ok t ->
    check_string
      "round-trips"
      "payments.Charged"
      (Sol_cli_plan_ids.Schema_subject.to_string t)
  | Error e -> Alcotest.fail e
;;

let test_schema_subject_empty_fails () =
  match Sol_cli_plan_ids.Schema_subject.of_string "" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected empty schema subject to fail"
;;

let test_consumer_group_valid () =
  match Sol_cli_plan_ids.Consumer_group.of_string "ws.comms.notify_worker" with
  | Ok t ->
    check_string
      "round-trips"
      "ws.comms.notify_worker"
      (Sol_cli_plan_ids.Consumer_group.to_string t)
  | Error e -> Alcotest.fail e
;;

let test_consumer_group_empty_fails () =
  match Sol_cli_plan_ids.Consumer_group.of_string "" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected empty consumer group to fail"
;;

let () =
  Alcotest.run
    "deployment_plan"
    [ ( "k8s_name"
      , [ Alcotest.test_case "underscore to hyphen" `Quick test_k8s_name_underscores
        ; Alcotest.test_case "worker suffix" `Quick test_k8s_name_worker
        ; Alcotest.test_case "no underscores" `Quick test_k8s_name_no_underscores
        ; Alcotest.test_case
            "invalid characters rejected"
            `Quick
            test_k8s_name_rejects_invalid_characters
        ; Alcotest.test_case "empty rejected" `Quick test_k8s_name_rejects_empty
        ; Alcotest.test_case "overlong rejected" `Quick test_k8s_name_rejects_overlong
        ] )
    ; ( "namespace"
      , [ Alcotest.test_case "workspace-domain" `Quick test_namespace
        ; Alcotest.test_case "comms domain" `Quick test_namespace_comms
        ; Alcotest.test_case
            "sanitize workspace"
            `Quick
            test_namespace_sanitizes_workspace
        ; Alcotest.test_case
            "uppercase workspace"
            `Quick
            test_namespace_uppercased_workspace
        ; Alcotest.test_case
            "invalid domain rejected"
            `Quick
            test_namespace_rejects_invalid_domain
        ; Alcotest.test_case "overlong rejected" `Quick test_namespace_rejects_overlong
        ] )
    ; ( "image_ref"
      , [ Alcotest.test_case "local k3d" `Quick test_image_ref_local
        ; Alcotest.test_case "ECR registry" `Quick test_image_ref_ecr
        ; Alcotest.test_case "localhost push" `Quick test_image_ref_push_registry
        ] )
    ; ( "to_json"
      , [ Alcotest.test_case "valid JSON" `Quick test_to_json_valid_json
        ; Alcotest.test_case "deterministic" `Quick test_to_json_deterministic
        ; Alcotest.test_case "no secret values" `Quick test_to_json_no_secret_values
        ; Alcotest.test_case "secret keys present" `Quick test_to_json_secret_keys_present
        ; Alcotest.test_case "env present" `Quick test_to_json_env_present
        ; Alcotest.test_case
            "config values present"
            `Quick
            test_to_json_config_values_present
        ; Alcotest.test_case "mode strings" `Quick test_to_json_mode_strings
        ; Alcotest.test_case "secret_backend present" `Quick test_to_json_secret_backend
        ; Alcotest.test_case
            "secret_backend values"
            `Quick
            test_to_json_secret_backend_values
        ; Alcotest.test_case
            "rollout_strategy rolling_update"
            `Quick
            test_to_json_rollout_strategy
        ; Alcotest.test_case
            "rollout_strategy recreate"
            `Quick
            test_to_json_rollout_strategy_recreate
        ; Alcotest.test_case
            "rollout_strategy canary"
            `Quick
            test_to_json_rollout_strategy_canary
        ; Alcotest.test_case
            "rollout_strategy blue_green"
            `Quick
            test_to_json_rollout_strategy_blue_green
        ; Alcotest.test_case
            "effective rollout default"
            `Quick
            test_effective_rollout_strategy_defaults_to_rolling_update
        ; Alcotest.test_case
            "effective rollout recreate"
            `Quick
            test_effective_rollout_strategy_recreate
        ; Alcotest.test_case
            "effective rollout precedence"
            `Quick
            test_effective_rollout_strategy_progressive_delivery_precedence
        ; Alcotest.test_case
            "summary rollout strategy"
            `Quick
            test_summary_uses_effective_rollout_strategy
        ; Alcotest.test_case
            "ingress null when absent"
            `Quick
            test_to_json_ingress_null_when_absent
        ; Alcotest.test_case
            "ingress host+path present"
            `Quick
            test_to_json_ingress_present
        ; Alcotest.test_case
            "schema_subjects in json"
            `Quick
            test_to_json_schema_subjects_present
        ; Alcotest.test_case
            "consumer_groups in json"
            `Quick
            test_to_json_consumer_groups_present
        ] )
    ; ( "discover_topics"
      , [ Alcotest.test_case
            "finds topic from sol.toml"
            `Quick
            test_discover_topics_finds_topic
        ; Alcotest.test_case
            "empty without events/"
            `Quick
            test_discover_topics_empty_when_no_dir
        ; Alcotest.test_case
            "multiple topics in one toml"
            `Quick
            test_discover_topics_multiple_topics_in_toml
        ; Alcotest.test_case "deduplicates" `Quick test_discover_topics_deduplicates
        ; Alcotest.test_case
            "subdirectory discovery"
            `Quick
            test_discover_topics_subdirectory
        ; Alcotest.test_case
            "top-level events/sol.toml"
            `Quick
            test_discover_topics_top_level_toml
        ; Alcotest.test_case
            "mixed top-level and subdir"
            `Quick
            test_discover_topics_mixed_levels
        ; Alcotest.test_case
            "no false positives from .ml files"
            `Quick
            test_discover_topics_no_false_positives_from_ml_files
        ] )
    ; ( "extract_schedule"
      , [ Alcotest.test_case
            "reads schedule from sol.toml"
            `Quick
            test_extract_schedule_reads_from_sol_toml
        ; Alcotest.test_case
            "default when no sol.toml"
            `Quick
            test_extract_schedule_defaults_when_no_toml
        ; Alcotest.test_case
            "default when no schedule key in toml"
            `Quick
            test_extract_schedule_defaults_when_no_schedule_key
        ; Alcotest.test_case
            "ignores ml source schedule pattern"
            `Quick
            test_extract_schedule_ignores_ml_source_pattern
        ] )
    ; ( "discover_migrations"
      , [ Alcotest.test_case "finds sql" `Quick test_discover_migrations_finds_sql
        ; Alcotest.test_case
            "empty without db/migrations/"
            `Quick
            test_discover_migrations_empty_when_no_dir
        ; Alcotest.test_case "sorted by name" `Quick test_discover_migrations_sorted
        ; Alcotest.test_case
            "ignores non-sql"
            `Quick
            test_discover_migrations_ignores_non_sql
        ] )
    ; ( "schema_subjects"
      , [ Alcotest.test_case
            "derived from events/<domain>/<event>.ml"
            `Quick
            test_schema_subjects_derived
        ; Alcotest.test_case
            "multiple domains sorted"
            `Quick
            test_schema_subjects_multiple_domains
        ; Alcotest.test_case "top-level ml file" `Quick test_schema_subjects_top_level_ml
        ; Alcotest.test_case
            "empty without events dir"
            `Quick
            test_schema_subjects_empty_when_no_dir
        ] )
    ; ( "consumer_groups"
      , [ Alcotest.test_case
            "derived from Worker spec"
            `Quick
            test_consumer_groups_derived
        ; Alcotest.test_case
            "excludes Svc primitives"
            `Quick
            test_consumer_groups_excludes_svc
        ; Alcotest.test_case "sorted" `Quick test_consumer_groups_sorted
        ] )
    ; ( "of_services"
      , [ Alcotest.test_case
            "returns typed TOML parse error"
            `Quick
            test_of_services_result_surfaces_toml_parse_error
        ; Alcotest.test_case
            "sol.yml scale_max overrides sol.toml replicas"
            `Quick
            test_sol_yml_scale_overrides_toml_replicas_on_resolved_target
        ; Alcotest.test_case
            "sol.yml scale_min used when no scale_max"
            `Quick
            test_sol_yml_scale_falls_back_to_scale_min_when_no_max
        ; Alcotest.test_case
            "no resolved config keeps sol.toml replicas"
            `Quick
            test_no_resolved_config_uses_toml_replicas
        ; Alcotest.test_case
            "no matching sol.yml service keeps sol.toml replicas"
            `Quick
            test_no_matching_sol_yml_service_uses_toml_replicas
        ; Alcotest.test_case
            "sol.toml volumes carry into service spec"
            `Quick
            test_toml_volumes_carry_into_service_spec
        ] )
    ; ( "plan_ids"
      , [ Alcotest.test_case "Topic_name valid" `Quick test_topic_name_valid
        ; Alcotest.test_case "Topic_name empty fails" `Quick test_topic_name_empty_fails
        ; Alcotest.test_case
            "Topic_name too long fails"
            `Quick
            test_topic_name_too_long_fails
        ; Alcotest.test_case
            "Topic_name invalid char fails"
            `Quick
            test_topic_name_invalid_char_fails
        ; Alcotest.test_case
            "Topic_name max length ok"
            `Quick
            test_topic_name_max_length_ok
        ; Alcotest.test_case "Migration_file valid" `Quick test_migration_file_valid
        ; Alcotest.test_case
            "Migration_file empty fails"
            `Quick
            test_migration_file_empty_fails
        ; Alcotest.test_case
            "Migration_file not-.sql fails"
            `Quick
            test_migration_file_not_sql_fails
        ; Alcotest.test_case "Schema_subject valid" `Quick test_schema_subject_valid
        ; Alcotest.test_case
            "Schema_subject empty fails"
            `Quick
            test_schema_subject_empty_fails
        ; Alcotest.test_case "Consumer_group valid" `Quick test_consumer_group_valid
        ; Alcotest.test_case
            "Consumer_group empty fails"
            `Quick
            test_consumer_group_empty_fails
        ] )
    ]
;;
