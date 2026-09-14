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

let base_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "payments"
  ; source_name = "charge_svc"
  ; k8s_name = k8s_name "charge-svc"
  ; namespace = namespace ~workspace:"myapp" ~domain:"payments"
  ; primitive = Sol_cli_deployment_plan.Svc
  ; source_dir = "app/payments/charge_svc"
  ; image = ""
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
  ; calls = []
  ; called_by = []
  ; extra_labels = []
  ; progressive_delivery = None
  }
;;

(* ── rollback_target_of_service ─────────────────────────────────────────── *)

let test_svc_gives_standard_deployment () =
  let spec = { base_spec with primitive = Sol_cli_deployment_plan.Svc } in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.Standard_deployment { namespace; name } ->
    Alcotest.(check string) "namespace" "myapp-payments" namespace;
    Alcotest.(check string) "name" "charge-svc" name
  | other ->
    let label =
      match other with
      | Sol_cli_rollback.Argo_rollout _ -> "Argo_rollout"
      | Sol_cli_rollback.No_op _ -> "No_op"
      | Sol_cli_rollback.Standard_deployment _ -> "Standard_deployment"
    in
    Alcotest.failf "expected Standard_deployment, got %s" label
;;

let test_worker_gives_standard_deployment () =
  let spec =
    { base_spec with
      primitive = Sol_cli_deployment_plan.Worker
    ; source_name = "notify_worker"
    ; k8s_name = k8s_name "notify-worker"
    ; namespace = namespace ~workspace:"myapp" ~domain:"comms"
    ; domain = "comms"
    }
  in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.Standard_deployment { namespace; name } ->
    Alcotest.(check string) "namespace" "myapp-comms" namespace;
    Alcotest.(check string) "name" "notify-worker" name
  | _ -> Alcotest.fail "expected Standard_deployment for worker"
;;

let test_fn_gives_no_op () =
  let spec =
    { base_spec with
      primitive = Sol_cli_deployment_plan.Fn
    ; source_name = "cleanup_fn"
    ; k8s_name = k8s_name "cleanup-fn"
    ; schedule = Some "0 * * * *"
    }
  in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.No_op reason -> assert (String.length reason > 0)
  | _ -> Alcotest.fail "expected No_op for Fn primitive"
;;

let test_progressive_delivery_gives_argo_rollout () =
  let spec =
    { base_spec with progressive_delivery = Some (Sol_cli_toml.Canary { steps = [] }) }
  in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.Argo_rollout { namespace; name } ->
    Alcotest.(check string) "namespace" "myapp-payments" namespace;
    Alcotest.(check string) "name" "charge-svc" name
  | _ -> Alcotest.fail "expected Argo_rollout for progressive_delivery=canary"
;;

let test_blue_green_gives_argo_rollout () =
  let spec = { base_spec with progressive_delivery = Some Sol_cli_toml.Blue_green } in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.Argo_rollout _ -> ()
  | _ -> Alcotest.fail "expected Argo_rollout for progressive_delivery=blue_green"
;;

let test_worker_with_argo_gives_argo_rollout () =
  let spec =
    { base_spec with
      primitive = Sol_cli_deployment_plan.Worker
    ; progressive_delivery = Some (Sol_cli_toml.Canary { steps = [] })
    }
  in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.Argo_rollout _ -> ()
  | _ -> Alcotest.fail "expected Argo_rollout for Worker with progressive_delivery"
;;

let test_fn_with_progressive_delivery_still_no_op () =
  let spec =
    { base_spec with
      primitive = Sol_cli_deployment_plan.Fn
    ; progressive_delivery = Some (Sol_cli_toml.Canary { steps = [] })
    }
  in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.No_op _ -> ()
  | _ ->
    Alcotest.fail
      "Fn primitive must always produce No_op regardless of progressive_delivery"
;;

(* ── execute_rollback No_op ─────────────────────────────────────────────── *)

let test_execute_no_op_returns_ok () =
  match
    Sol_cli_rollback.execute_rollback
      ~ctx:Sol_cli_kube_destination.local_context
      (Sol_cli_rollback.No_op "test reason")
  with
  | Ok () -> ()
  | Error e ->
    Alcotest.failf "expected Ok, got error: %s" (Sol_cli_rollback.error_to_string e)
;;

(* ── Plugin_missing error_to_string ─────────────────────────────────────── *)

let test_plugin_missing_error_contains_install_link () =
  let err =
    Sol_cli_rollback.Plugin_missing { namespace = "myapp-payments"; name = "charge-svc" }
  in
  let msg = Sol_cli_rollback.error_to_string err in
  assert (
    let re = Str.regexp "argoproj.github.io" in
    try
      ignore (Str.search_forward re msg 0);
      true
    with
    | Not_found -> false);
  assert (
    let re = Str.regexp "kubectl argo rollouts undo" in
    try
      ignore (Str.search_forward re msg 0);
      true
    with
    | Not_found -> false)
;;

let test_plugin_missing_error_contains_namespace_and_name () =
  let err =
    Sol_cli_rollback.Plugin_missing { namespace = "myapp-payments"; name = "charge-svc" }
  in
  let msg = Sol_cli_rollback.error_to_string err in
  assert (
    let re = Str.regexp "myapp-payments" in
    try
      ignore (Str.search_forward re msg 0);
      true
    with
    | Not_found -> false);
  assert (
    let re = Str.regexp "charge-svc" in
    try
      ignore (Str.search_forward re msg 0);
      true
    with
    | Not_found -> false)
;;

let test_non_zero_error_to_string () =
  let err =
    Sol_cli_rollback.Non_zero { command = "kubectl rollout undo"; exit_code = 1 }
  in
  let msg = Sol_cli_rollback.error_to_string err in
  assert (
    let re = Str.regexp "kubectl rollout undo" in
    try
      ignore (Str.search_forward re msg 0);
      true
    with
    | Not_found -> false);
  assert (
    let re = Str.regexp "1" in
    try
      ignore (Str.search_forward re msg 0);
      true
    with
    | Not_found -> false)
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

let gate_release = Sol_cli_release.of_plan gate_plan

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

let () =
  Alcotest.run
    "rollback"
    [ ( "rollback_target_of_service"
      , [ Alcotest.test_case
            "Svc -> Standard_deployment"
            `Quick
            test_svc_gives_standard_deployment
        ; Alcotest.test_case
            "Worker -> Standard_deployment"
            `Quick
            test_worker_gives_standard_deployment
        ; Alcotest.test_case "Fn -> No_op" `Quick test_fn_gives_no_op
        ; Alcotest.test_case
            "canary -> Argo_rollout"
            `Quick
            test_progressive_delivery_gives_argo_rollout
        ; Alcotest.test_case
            "blue_green -> Argo_rollout"
            `Quick
            test_blue_green_gives_argo_rollout
        ; Alcotest.test_case
            "Worker+canary -> Argo_rollout"
            `Quick
            test_worker_with_argo_gives_argo_rollout
        ; Alcotest.test_case
            "Fn+canary still No_op"
            `Quick
            test_fn_with_progressive_delivery_still_no_op
        ] )
    ; ( "execute_rollback"
      , [ Alcotest.test_case "No_op always Ok" `Quick test_execute_no_op_returns_ok ] )
    ; ( "error_to_string"
      , [ Alcotest.test_case
            "Plugin_missing contains install URL"
            `Quick
            test_plugin_missing_error_contains_install_link
        ; Alcotest.test_case
            "Plugin_missing contains names"
            `Quick
            test_plugin_missing_error_contains_namespace_and_name
        ; Alcotest.test_case
            "Non_zero contains command and code"
            `Quick
            test_non_zero_error_to_string
        ] )
    ; ( "reconstruction_gate"
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
    ]
;;
