let release_id_of_test =
  Sol_cli_release_id.of_content { workspace = "test"; environment = None; workloads = [] }
;;

let expected_release_label =
  Printf.sprintf {|release: "%s"|} (Sol_cli_release_id.to_string release_id_of_test)
;;

let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

let render_spec_ok
      ?(workspace = "myapp")
      ?env
      ?image
      ?(release_id = release_id_of_test)
      ?secret_backend
      spec
  =
  match
    Sol_cli_deployment_render.render_spec
      ~workspace
      ?env
      ?image
      ~release_id
      ?secret_backend
      spec
  with
  | Ok v -> v
  | Error e -> Alcotest.fail ("render_spec unexpectedly failed: " ^ e)
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

let contains haystack needle = Sol_cli_string.contains ~needle haystack
let render_doc doc = Sol_cli_yaml.render [ doc ]

let load_toml path =
  match Sol_cli_toml.load_result path with
  | Ok toml -> toml
  | Error err -> Alcotest.fail (Sol_cli_toml.parse_error_to_string err)
;;

let assert_contains label haystack needle =
  check_bool
    (Printf.sprintf "%s: contains %S" label needle)
    true
    (contains haystack needle)
;;

let assert_absent label haystack needle =
  check_bool
    (Printf.sprintf "%s: absent %S" label needle)
    false
    (contains haystack needle)
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

let extract_kind_block yaml kind_marker =
  let sep = "\n---" in
  let sl = String.length sep in
  let yl = String.length yaml in
  let blocks = ref [] in
  let start = ref 0 in
  for i = 0 to yl - sl do
    if String.sub yaml i sl = sep
    then (
      blocks := String.sub yaml !start (i - !start) :: !blocks;
      start := i + 1)
  done;
  blocks := String.sub yaml !start (yl - !start) :: !blocks;
  let result = ref "" in
  List.rev !blocks
  |> List.iter (fun b -> if !result = "" && contains b kind_marker then result := b);
  !result
;;

let svc_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "payments"
  ; source_name = "charge_svc"
  ; k8s_name = k8s_name "charge-svc"
  ; namespace = namespace ~workspace:"myapp" ~domain:"payments"
  ; primitive = Sol_cli_deployment_plan.Svc
  ; source_dir = "app/payments/charge_svc"
  ; image = "sol-registry:5000/myapp/charge-svc:abc123"
  ; config = [ "APP_ENV", "staging" ]
  ; secrets = []
  ; volumes = []
  ; schedule = None
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; replicas = 2
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu = cpu "200m"
  ; memory = memory "256Mi"
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
  ; namespace = namespace ~workspace:"myapp" ~domain:"comms"
  ; primitive = Sol_cli_deployment_plan.Worker
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; source_dir = "app/comms/notify_worker"
  ; image = "sol-registry:5000/myapp/notify-worker:abc123"
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
  ; image = "sol-registry:5000/myapp/invoice-fn:abc123"
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

let test_volume : Sol_cli_toml.volume =
  { name = "data"
  ; mount_path = "/var/lib/data"
  ; size = "10Gi"
  ; access_mode = Sol_cli_toml.ReadWriteOnce
  }
;;

let with_volumes volumes (spec : Sol_cli_deployment_plan.service_spec) =
  { spec with volumes }
;;

let test_svc_volumes () =
  let _, workload = render_spec_ok (with_volumes [ test_volume ] svc_spec) in
  assert_contains "svc PVC" workload "kind: PersistentVolumeClaim";
  assert_contains "svc PVC name" workload "name: charge-svc-data";
  assert_contains "svc mountPath" workload "mountPath: /var/lib/data";
  assert_contains "svc claimName" workload "claimName: charge-svc-data";
  assert_contains "svc storage" workload "storage: 10Gi"
;;

let test_worker_volumes () =
  let _, workload = render_spec_ok (with_volumes [ test_volume ] worker_spec) in
  assert_contains "worker PVC name" workload "name: notify-worker-data";
  assert_contains "worker mountPath" workload "mountPath: /var/lib/data";
  assert_contains "worker claimName" workload "claimName: notify-worker-data"
;;

let test_svc_namespace () =
  let ns_yaml, _workload = render_spec_ok svc_spec in
  assert_contains "svc ns_yaml" ns_yaml "name: myapp-payments"
;;

let test_svc_deployment_name () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc deployment name" workload "name: charge-svc"
;;

let test_svc_image () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc image" workload "sol-registry:5000/myapp/charge-svc:abc123"
;;

let test_svc_has_service_resource () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc Service resource" workload "kind: Service\n"
;;

let test_svc_has_ingress () =
  let _ns, workload = render_spec_ok svc_spec in
  let ingress_block = extract_kind_block workload "kind: Ingress" in
  assert_contains "svc Ingress resource" workload "kind: Ingress";
  assert_contains
    "ingress pins the nginx IngressClass"
    ingress_block
    "ingressClassName: nginx"
;;

let test_svc_networkpolicy_allows_monitoring_ingress () =
  let _ns, workload = render_spec_ok svc_spec in
  let netpol_block = extract_kind_block workload "kind: NetworkPolicy" in
  let ingress_block =
    match Str.bounded_split_delim (Str.regexp_string "\n  egress:") netpol_block 2 with
    | ingress_part :: _ -> ingress_part
    | [] -> netpol_block
  in
  assert_contains
    "svc NetworkPolicy ingress allows monitoring namespace"
    ingress_block
    "kubernetes.io/metadata.name: monitoring"
;;

let test_svc_calls_peer_env_and_network_policy () =
  let checkout =
    { Sol_cli_deployment_plan.env_var = "CHECKOUT_SVC_URL"
    ; url = "http://checkout-svc.myapp-checkout.svc.cluster.local"
    ; target_domain = "checkout"
    ; target_name = k8s_name "checkout-svc"
    ; target_namespace = namespace ~workspace:"myapp" ~domain:"checkout"
    }
  in
  let payments =
    { Sol_cli_deployment_plan.env_var = "CHARGE_SVC_URL"
    ; url = "http://charge-svc.myapp-payments.svc.cluster.local"
    ; target_domain = "payments"
    ; target_name = k8s_name "charge-svc"
    ; target_namespace = namespace ~workspace:"myapp" ~domain:"payments"
    }
  in
  let caller =
    { svc_spec with calls = [ checkout ]; config = [ checkout.env_var, checkout.url ] }
  in
  let callee =
    { svc_spec with
      domain = "checkout"
    ; source_name = "checkout_svc"
    ; k8s_name = k8s_name "checkout-svc"
    ; namespace = namespace ~workspace:"myapp" ~domain:"checkout"
    ; called_by = [ payments ]
    }
  in
  let _ns, caller_yaml = render_spec_ok caller in
  let caller_cm = extract_kind_block caller_yaml "kind: ConfigMap" in
  let caller_netpol = extract_kind_block caller_yaml "kind: NetworkPolicy" in
  assert_contains
    "peer url env"
    caller_cm
    {|CHECKOUT_SVC_URL: "http://checkout-svc.myapp-checkout.svc.cluster.local"|};
  assert_contains "egress peer namespace" caller_netpol "myapp-checkout";
  assert_contains "egress peer app" caller_netpol "app: checkout-svc";
  let egress_block =
    match Str.bounded_split_delim (Str.regexp_string "\n  egress:") caller_netpol 2 with
    | _ :: rest -> String.concat "\n  egress:" rest
    | [] -> caller_netpol
  in
  assert_absent "caller egress is not port-pinned" egress_block "port: 8080";
  let _ns, callee_yaml = render_spec_ok callee in
  let callee_netpol = extract_kind_block callee_yaml "kind: NetworkPolicy" in
  assert_contains "ingress caller namespace" callee_netpol "myapp-payments";
  assert_contains "ingress caller app" callee_netpol "app: charge-svc";
  assert_contains "ingress uses the container port" callee_netpol "port: 8080"
;;

let test_svc_has_ports () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc containerPort" workload "containerPort: 8080"
;;

let test_svc_replicas () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc replicas=2" workload "replicas: 2"
;;

let test_svc_default_resources () =
  let default_spec =
    { svc_spec with replicas = 1; cpu = cpu "100m"; memory = memory "128Mi" }
  in
  let _ns, workload = render_spec_ok default_spec in
  assert_contains "svc default replicas=1" workload "replicas: 1";
  assert_contains "svc default cpu=100m" workload "cpu: 100m";
  assert_contains "svc default memory=128Mi" workload "memory: 128Mi"
;;

let test_svc_extra_config () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc extra configmap key" workload {|APP_ENV: "staging"|}
;;

let test_svc_env_label_present_when_resolved () =
  let _ns, workload = render_spec_ok ~env:"prod" svc_spec in
  assert_contains "svc env label" workload {|env: "prod"|}
;;

let test_svc_env_label_absent_by_default () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_absent "svc env label" workload {|env: "|}
;;

let test_svc_sol_env_configmap_present_when_resolved () =
  let _ns, workload = render_spec_ok ~env:"prod" svc_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_contains "svc SOL_ENV config" cm_block {|SOL_ENV: "prod"|}
;;

let test_svc_sol_env_configmap_absent_by_default () =
  let _ns, workload = render_spec_ok svc_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_absent "svc SOL_ENV config" cm_block {|SOL_ENV: |}
;;

let test_svc_sol_env_configmap_target_overrides_config () =
  let spec = { svc_spec with config = [ "SOL_ENV", "user-value" ] } in
  let _ns, workload = render_spec_ok ~env:"prod" spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_contains "svc SOL_ENV target value" cm_block {|SOL_ENV: "prod"|};
  assert_absent "svc SOL_ENV user value" cm_block "user-value"
;;

let test_worker_env_label_present_when_resolved () =
  let _ns, workload = render_spec_ok ~env:"staging" worker_spec in
  assert_contains "worker env label" workload {|env: "staging"|}
;;

let test_fn_env_label_present_when_resolved () =
  let _ns, workload = render_spec_ok ~env:"dev" fn_spec in
  assert_contains "fn env label" workload {|env: "dev"|}
;;

let test_svc_default_postgres_url () =
  let _ns, workload = render_spec_ok svc_spec in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "svc default postgres url in secret" secret_block {|POSTGRES_URL: ""|}
;;

let test_postgres_url_not_in_configmap () =
  let _ns, workload = render_spec_ok svc_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_absent "POSTGRES_URL absent from ConfigMap" cm_block "POSTGRES_URL"
;;

let test_postgres_url_in_secret () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "Secret resource present" workload "kind: Secret";
  assert_contains "stringData section" workload "stringData:";
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "POSTGRES_URL in stringData" secret_block {|POSTGRES_URL: ""|};
  assert_contains "SOL_API_KEY in stringData" secret_block {|SOL_API_KEY: ""|}
;;

let test_live_secret_uses_postgres_url_env () =
  Unix.putenv "POSTGRES_URL" "postgresql://user:pass@db.example.com:5432/app";
  let _ns, workload = render_spec_ok svc_spec in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains
    "POSTGRES_URL env value in live Secret"
    secret_block
    {|POSTGRES_URL: "postgresql://user:pass@db.example.com:5432/app"|};
  Unix.putenv "POSTGRES_URL" ""
;;

let test_svc_default_redpanda_admin_url () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains
    "svc default redpanda admin url"
    workload
    {|REDPANDA_ADMIN_URL: "http://redpanda.redpanda.svc.cluster.local:9644"|}
;;

let test_svc_declares_kafka_security_protocol () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains
    "svc declares the Kafka transport posture"
    workload
    {|KAFKA_SECURITY_PROTOCOL: "plaintext"|}
;;

let test_svc_secret_refs_without_values () =
  let spec =
    { svc_spec with
      secrets = [ "DATABASE_URL", "postgres://secret"; "API_TOKEN", "token-value" ]
    }
  in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  assert_contains "database secret ref" workload "key: DATABASE_URL";
  assert_contains "api token secret ref" workload "key: API_TOKEN";
  assert_absent "database value absent" workload "postgres://secret";
  assert_absent "token value absent" workload "token-value";
  assert_contains "shared secret name" workload "name: charge-svc-secrets"
;;

let test_svc_namespace_in_workload () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc workload namespace" workload "namespace: myapp-payments"
;;

let test_user_secret_key_in_secret_resource () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "STRIPE_KEY present in Secret resource" secret_block "STRIPE_KEY:"
;;

let test_user_secret_key_ref_in_deployment () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  assert_contains "STRIPE_KEY secretKeyRef" workload "key: STRIPE_KEY"
;;

let test_multiple_user_secret_keys_in_secret_resource () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", ""; "SENDGRID_API_KEY", "" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "STRIPE_KEY in Secret" secret_block "STRIPE_KEY:";
  assert_contains "SENDGRID_API_KEY in Secret" secret_block "SENDGRID_API_KEY:"
;;

let test_default_secrets_preserved_with_user_secrets () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "POSTGRES_URL still in Secret" secret_block "POSTGRES_URL:";
  assert_contains "STRIPE_KEY also in Secret" secret_block "STRIPE_KEY:"
;;

let test_gitops_redacts_all_secret_values () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "sk_live_should_not_render" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "redaction comment" secret_block "Populate these values before applying";
  assert_contains "default POSTGRES_URL key retained" secret_block {|POSTGRES_URL: ""|};
  assert_contains "user STRIPE_KEY key retained" secret_block {|STRIPE_KEY: ""|};
  assert_absent
    "default postgres value redacted"
    secret_block
    "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev";
  assert_absent "user secret value redacted" secret_block "sk_live_should_not_render"
;;

let test_worker_user_secret_key_in_secret_resource () =
  let spec = { worker_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "worker STRIPE_KEY in Secret" secret_block "STRIPE_KEY:"
;;

let test_fn_user_secret_key_in_secret_resource () =
  let spec = { fn_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "fn STRIPE_KEY in Secret" secret_block "STRIPE_KEY:"
;;

let test_svc_image_override () =
  let push_image = "localhost:5000/myapp/charge-svc:abc123" in
  let _ns, workload = render_spec_ok ~image:push_image svc_spec in
  assert_contains
    "svc push image in dry-run"
    workload
    "localhost:5000/myapp/charge-svc:abc123";
  assert_absent
    "svc cluster image absent"
    workload
    "sol-registry:5000/myapp/charge-svc:abc123"
;;

let test_worker_namespace () =
  let ns_yaml, _ = render_spec_ok worker_spec in
  assert_contains "worker ns" ns_yaml "name: myapp-comms"
;;

let test_worker_image () =
  let _ns, workload = render_spec_ok worker_spec in
  assert_contains "worker image" workload "sol-registry:5000/myapp/notify-worker:abc123"
;;

let test_worker_no_service_resource () =
  let _ns, workload = render_spec_ok worker_spec in
  assert_absent "worker no Service resource" workload "kind: Service\n";
  assert_absent "worker no Ingress" workload "kind: Ingress"
;;

let test_worker_metrics_port () =
  let _ns, workload = render_spec_ok worker_spec in
  assert_contains "worker metrics containerPort" workload "containerPort: 9090";
  assert_contains "worker prometheus scrape" workload "prometheus.io/scrape: \"true\"";
  assert_contains "worker prometheus port" workload "prometheus.io/port: \"9090\""
;;

let test_worker_has_deployment () =
  let _ns, workload = render_spec_ok worker_spec in
  assert_contains "worker Deployment" workload "kind: Deployment"
;;

let test_service_account_disables_token_automount () =
  let ns_yaml, workload = render_spec_ok worker_spec in
  let rendered = ns_yaml ^ workload in
  assert_contains "ServiceAccount rendered" rendered "kind: ServiceAccount";
  assert_contains "automount disabled" rendered "automountServiceAccountToken: false";
  assert_absent
    "pod does not re-enable automount"
    workload
    "automountServiceAccountToken: true"
;;

let test_svc_service_account_disables_token_automount () =
  let ns_yaml, workload = render_spec_ok svc_spec in
  let rendered = ns_yaml ^ workload in
  assert_contains "svc ServiceAccount rendered" rendered "kind: ServiceAccount";
  assert_contains "svc automount disabled" rendered "automountServiceAccountToken: false";
  assert_absent
    "svc pod does not re-enable automount"
    workload
    "automountServiceAccountToken: true"
;;

let test_fn_service_account_disables_token_automount () =
  let ns_yaml, workload = render_spec_ok fn_spec in
  let rendered = ns_yaml ^ workload in
  assert_contains "fn ServiceAccount rendered" rendered "kind: ServiceAccount";
  assert_contains "fn automount disabled" rendered "automountServiceAccountToken: false"
;;

let test_termination_grace_is_explicit () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains
    "explicit termination grace (drain has room before SIGKILL)"
    workload
    "terminationGracePeriodSeconds: 45"
;;

let test_worker_consumer_probes () =
  let _ns, workload = render_spec_ok { worker_spec with consumes_kafka = true } in
  assert_contains "consumer readiness endpoint" workload "path: /readyz";
  assert_contains "consumer liveness endpoint" workload "path: /livez";
  assert_contains "consumer startup probe" workload "startupProbe:"
;;

let test_non_consumer_worker_has_no_liveness () =
  let _ns, workload = render_spec_ok worker_spec in
  assert_absent
    "a worker with no consumer state claims no liveness"
    workload
    "livenessProbe:"
;;

let test_node_failure_tolerant_renders_pdb_and_spread () =
  let spec =
    { svc_spec with
      availability = Sol_cli_availability.Node_failure_tolerant
    ; replicas = 2
    }
  in
  let _ns, workload = render_spec_ok spec in
  assert_contains "PodDisruptionBudget rendered" workload "kind: PodDisruptionBudget";
  assert_contains "budget keeps one replica available" workload "minAvailable: 1";
  assert_contains "topology spread constraint" workload "topologySpreadConstraints:";
  assert_contains
    "spread keyed on the node"
    workload
    "topologyKey: kubernetes.io/hostname"
;;

let test_single_has_no_pdb () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_absent
    "a single workload claims no disruption budget"
    workload
    "PodDisruptionBudget"
;;

let test_fn_namespace () =
  let ns_yaml, _ = render_spec_ok fn_spec in
  assert_contains "fn ns" ns_yaml "name: myapp-billing"
;;

let test_fn_image () =
  let _ns, workload = render_spec_ok fn_spec in
  assert_contains "fn image" workload "sol-registry:5000/myapp/invoice-fn:abc123"
;;

let test_fn_cronjob () =
  let _ns, workload = render_spec_ok fn_spec in
  assert_contains "fn CronJob kind" workload "kind: CronJob"
;;

let test_fn_schedule () =
  let _ns, workload = render_spec_ok fn_spec in
  assert_contains "fn schedule" workload {|schedule: "0 9 * * 1"|}
;;

let test_fn_no_deployment () =
  let _ns, workload = render_spec_ok fn_spec in
  assert_absent "fn no Deployment" workload "kind: Deployment"
;;

let test_fn_cronjob_pod_template_has_app_label () =
  let _ns, workload = render_spec_ok fn_spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  assert_contains "fn cronjob pod template app label" cronjob_block "app: invoice-fn"
;;

let test_fn_cpu_memory_configurable () =
  let spec = { fn_spec with cpu = cpu "2"; memory = memory "4Gi" } in
  let _ns, workload = render_spec_ok spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  assert_contains "fn configured cpu request" cronjob_block {|cpu: "2"|};
  assert_contains "fn configured memory request" cronjob_block "memory: 4Gi"
;;

let test_fn_cpu_memory_request_equals_limit () =
  let spec = { fn_spec with cpu = cpu "500m"; memory = memory "1Gi" } in
  let _ns, workload = render_spec_ok spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  let count_occurrences needle haystack =
    let n = String.length needle
    and s = String.length haystack in
    let count = ref 0 in
    for i = 0 to s - n do
      if String.sub haystack i n = needle then incr count
    done;
    !count
  in
  Alcotest.(check int)
    "cpu: 500m appears twice (requests and limits)"
    2
    (count_occurrences "cpu: 500m" cronjob_block);
  Alcotest.(check int)
    "memory: 1Gi appears twice (requests and limits)"
    2
    (count_occurrences "memory: 1Gi" cronjob_block)
;;

let test_fn_scheduled_concurrency_configurable () =
  let spec = { fn_spec with scheduled_concurrency = Sol_cli_toml.Forbid } in
  let _ns, workload = render_spec_ok spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  assert_contains "fn concurrencyPolicy: Forbid" cronjob_block "concurrencyPolicy: Forbid"
;;

let test_fn_scheduled_concurrency_default_is_allow () =
  let _ns, workload = render_spec_ok fn_spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  assert_contains
    "fn default concurrencyPolicy: Allow"
    cronjob_block
    "concurrencyPolicy: Allow"
;;

let test_fn_backoff_limit_configurable () =
  let spec = { fn_spec with backoff_limit = 7 } in
  let _ns, workload = render_spec_ok spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  assert_contains "fn backoffLimit: 7" cronjob_block "backoffLimit: 7"
;;

let test_fn_backoff_limit_default_is_three () =
  let _ns, workload = render_spec_ok fn_spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  assert_contains "fn default backoffLimit: 3" cronjob_block "backoffLimit: 3"
;;

let test_rollout_recreate () =
  let spec = { svc_spec with rollout_strategy = Some Sol_cli_toml.Recreate } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "recreate strategy" workload "type: Recreate";
  assert_absent "no RollingUpdate" workload "type: RollingUpdate"
;;

let test_rollout_rolling_update () =
  let spec = { svc_spec with rollout_strategy = Some Sol_cli_toml.RollingUpdate } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "rolling strategy" workload "type: RollingUpdate";
  assert_absent "no Recreate" workload "type: Recreate"
;;

let test_rollout_default_is_rolling_update () =
  let spec = { svc_spec with rollout_strategy = None } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "default is RollingUpdate" workload "type: RollingUpdate"
;;

let test_progressive_default_is_deployment () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "default Deployment" workload "kind: Deployment";
  assert_absent "default no Rollout" workload "kind: Rollout"
;;

let test_progressive_canary_rollout () =
  let spec =
    { svc_spec with
      progressive_delivery =
        Some
          (Sol_cli_toml.Canary
             { steps =
                 [ Sol_cli_toml.Weight 10
                 ; Sol_cli_toml.Weight 40
                 ; Sol_cli_toml.Weight 100
                 ]
             })
    }
  in
  let _ns, workload = render_spec_ok spec in
  assert_contains "rollout api" workload "apiVersion: argoproj.io/v1alpha1";
  assert_contains "rollout kind" workload "kind: Rollout";
  assert_contains "canary block" workload "canary:";
  assert_contains "weight 10" workload "setWeight: 10";
  assert_contains "weight 40" workload "setWeight: 40";
  assert_contains "weight 100" workload "setWeight: 100";
  assert_contains "svc port preserved" workload "containerPort: 8080";
  assert_contains "svc probes preserved" workload "readinessProbe:";
  assert_absent "no Deployment" workload "kind: Deployment"
;;

let test_progressive_canary_worker_no_service () =
  let spec =
    { worker_spec with
      progressive_delivery =
        Some (Sol_cli_toml.Canary { steps = [ Sol_cli_toml.Weight 50 ] })
    }
  in
  let _ns, workload = render_spec_ok spec in
  assert_contains "worker rollout kind" workload "kind: Rollout";
  assert_contains "worker canary step" workload "setWeight: 50";
  assert_absent "worker no ingress" workload "kind: Ingress";
  assert_absent "worker no service port" workload "port: 80";
  assert_absent "worker no port" workload "containerPort: 8080"
;;

let test_progressive_blue_green_rollout () =
  let spec = { svc_spec with progressive_delivery = Some Sol_cli_toml.Blue_green } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "rollout kind" workload "kind: Rollout";
  assert_contains "blueGreen block" workload "blueGreen:";
  assert_contains "active service strategy" workload "activeService: charge-svc-active";
  assert_contains "preview service strategy" workload "previewService: charge-svc-preview";
  assert_contains "manual promotion" workload "autoPromotionEnabled: false";
  assert_contains "active service manifest" workload "name: charge-svc-active";
  assert_contains "preview service manifest" workload "name: charge-svc-preview";
  assert_contains "ingress points at active" workload "name: charge-svc-active";
  assert_absent "no Deployment" workload "kind: Deployment"
;;

let test_rollout_canary_secrets_use_sol_secrets () =
  let spec =
    { svc_spec with
      progressive_delivery =
        Some
          (Sol_cli_toml.Canary
             { steps = [ Sol_cli_toml.Weight 50; Sol_cli_toml.Weight 100 ] })
    ; secrets = [ "STRIPE_KEY", ""; "DATABASE_URL", "" ]
    }
  in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  let rollout_block = extract_kind_block workload "kind: Rollout" in
  assert_contains
    "rollout uses charge-svc-secrets ref"
    rollout_block
    "name: charge-svc-secrets";
  assert_contains "rollout has STRIPE_KEY ref" rollout_block "key: STRIPE_KEY";
  assert_contains "rollout has DATABASE_URL ref" rollout_block "key: DATABASE_URL";
  assert_absent "no global sol-secrets name" rollout_block "name: sol-secrets"
;;

let test_rollout_blue_green_secrets_use_sol_secrets () =
  let spec =
    { svc_spec with
      progressive_delivery = Some Sol_cli_toml.Blue_green
    ; secrets = [ "API_TOKEN", "" ]
    }
  in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  let rollout_block = extract_kind_block workload "kind: Rollout" in
  assert_contains
    "blue-green rollout uses charge-svc-secrets"
    rollout_block
    "name: charge-svc-secrets";
  assert_contains "blue-green rollout has API_TOKEN ref" rollout_block "key: API_TOKEN";
  assert_absent "no global sol-secrets name" rollout_block "name: sol-secrets"
;;

let test_ingress_host_override () =
  let spec =
    { svc_spec with
      ingress_host = Some (hostname "payments.example.com")
    ; cluster_issuer = "letsencrypt-staging"
    }
  in
  let _ns, workload = render_spec_ok spec in
  let ingress_block = extract_kind_block workload "kind: Ingress" in
  assert_contains
    "ingress host rule"
    ingress_block
    "  - host: payments.example.com\n    http:";
  assert_contains
    "cert-manager issuer"
    ingress_block
    "cert-manager.io/cluster-issuer: letsencrypt-staging";
  assert_contains
    "tls host"
    ingress_block
    {|tls:
  - hosts:
    - payments.example.com|};
  assert_contains "tls secret" ingress_block "secretName: charge-svc-tls";
  assert_contains
    "host ingress still pins the nginx IngressClass"
    ingress_block
    "ingressClassName: nginx"
;;

let test_undeclared_ingress_host_gets_dev_host () =
  let _ns, workload = render_spec_ok svc_spec in
  let ingress_block = extract_kind_block workload "kind: Ingress" in
  assert_contains
    "dev host rule"
    ingress_block
    "  - host: charge-svc.myapp-payments.localhost";
  assert_absent "no issuer for dev host" ingress_block "cert-manager.io/cluster-issuer";
  assert_absent "no ssl redirect for dev host" ingress_block "ssl-redirect";
  assert_absent "no tls for dev host" ingress_block "tls:"
;;

let test_blue_green_ingress_tls_secret_matches_plan () =
  let spec =
    { svc_spec with
      ingress_host = Some (hostname "payments.example.com")
    ; progressive_delivery = Some Sol_cli_toml.Blue_green
    }
  in
  let _ns, workload = render_spec_ok spec in
  let ingress_block = extract_kind_block workload "kind: Ingress" in
  assert_contains
    "ingress points at active service"
    ingress_block
    "name: charge-svc-active";
  assert_contains "tls secret matches plan" ingress_block "secretName: charge-svc-tls"
;;

let test_ingress_path_override () =
  let spec = { svc_spec with ingress_path = Some (ingress_path "/api/v2") } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "ingress path" workload "path: /api/v2"
;;

let test_ingress_default_path () =
  let spec = { svc_spec with ingress_path = None } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "default path" workload "path: /"
;;

let test_extra_labels_appear_in_pod_template () =
  let spec = { svc_spec with extra_labels = [ "team", "platform"; "tier", "backend" ] } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "extra label team" workload {|team: "platform"|};
  assert_contains "extra label tier" workload {|tier: "backend"|}
;;

let test_extra_labels_empty_by_default () =
  let spec = { svc_spec with extra_labels = [] } in
  let _ns, workload = render_spec_ok spec in
  assert_absent "no team label" workload {|team:|}
;;

let test_toml_invalid_rollout_strategy () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.deploy]\nrollout_strategy = \"Blue/Green\"\n";
  close_out oc;
  let raised = Result.is_error (Sol_cli_toml.load_result path) in
  Sys.remove path;
  check_bool "invalid rollout_strategy raises" true raised
;;

let test_toml_reserved_label_key () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.labels]
extra_labels = { "sol.dev/owner" = "platform" }
|};
  close_out oc;
  let raised = Result.is_error (Sol_cli_toml.load_result path) in
  Sys.remove path;
  check_bool "reserved label key raises" true raised
;;

let test_toml_valid_rollout_recreate () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.deploy]\nrollout_strategy = \"Recreate\"\n";
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  check_bool
    "rollout_strategy is Recreate"
    true
    (toml.rollout_strategy = Some Sol_cli_toml.Recreate)
;;

let test_toml_valid_ingress_overrides () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.deploy]
ingress_host = "api.example.com"
ingress_path = "/v1"
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  check_bool
    "ingress_host parsed"
    true
    (Option.map Sol_cli_toml.hostname_to_string toml.ingress_host = Some "api.example.com");
  check_bool
    "ingress_path parsed"
    true
    (Option.map Sol_cli_toml.ingress_path_to_string toml.ingress_path = Some "/v1")
;;

let test_toml_valid_service_calls () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[service]
calls = ["checkout/checkout_svc"]
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  Alcotest.(check (list string)) "calls parsed" [ "checkout/checkout_svc" ] toml.calls
;;

let test_toml_invalid_cpu_quantity () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.scale]
cpu = "250Mi"
|};
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    assert_contains "invalid cpu quantity" message "cpu quantity"
  | Ok _ -> Alcotest.fail "expected invalid CPU quantity to be rejected"
  | Error (Sol_cli_toml.Toml_syntax _) ->
    Alcotest.fail "expected validation error, got syntax error"
;;

let test_toml_invalid_memory_quantity () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.scale]
memory = "many"
|};
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    assert_contains "invalid memory quantity" message "memory quantity"
  | Ok _ -> Alcotest.fail "expected invalid memory quantity to be rejected"
  | Error (Sol_cli_toml.Toml_syntax _) ->
    Alcotest.fail "expected validation error, got syntax error"
;;

let test_toml_invalid_ingress_host () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.deploy]
ingress_host = "Bad_Host.example.com"
|};
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    assert_contains "invalid ingress host" message "ingress_host"
  | Ok _ -> Alcotest.fail "expected invalid ingress_host to be rejected"
  | Error (Sol_cli_toml.Toml_syntax _) ->
    Alcotest.fail "expected validation error, got syntax error"
;;

let test_toml_invalid_ingress_path () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.deploy]
ingress_path = "api/v1"
|};
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    assert_contains "invalid ingress path" message "ingress_path"
  | Ok _ -> Alcotest.fail "expected invalid ingress_path to be rejected"
  | Error (Sol_cli_toml.Toml_syntax _) ->
    Alcotest.fail "expected validation error, got syntax error"
;;

let test_toml_secret_keys () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.env]
secrets = ["DATABASE_URL", "API_TOKEN"]
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  check_bool "secret keys parsed" true (toml.secret_keys = [ "DATABASE_URL"; "API_TOKEN" ])
;;

let test_toml_valid_canary_rollout () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.rollout]
strategy = "canary"
steps = [10, 40, 100]
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  match toml.progressive_delivery with
  | Some
      (Sol_cli_toml.Canary
         { steps =
             [ Sol_cli_toml.Weight 10; Sol_cli_toml.Weight 40; Sol_cli_toml.Weight 100 ]
         }) -> ()
  | _ -> Alcotest.fail "expected canary progressive_delivery from [infra.rollout]"
;;

let test_toml_valid_blue_green_rollout () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.rollout]
strategy = "blue-green"
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  check_bool
    "blue-green parsed"
    true
    (toml.progressive_delivery = Some Sol_cli_toml.Blue_green)
;;

let test_toml_invalid_progressive_strategy () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.rollout]
strategy = "rolling"
|};
  close_out oc;
  let raised = Result.is_error (Sol_cli_toml.load_result path) in
  Sys.remove path;
  check_bool "invalid progressive strategy raises" true raised
;;

let test_toml_canary_requires_steps () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.rollout]
strategy = "canary"
|};
  close_out oc;
  let raised = Result.is_error (Sol_cli_toml.load_result path) in
  Sys.remove path;
  check_bool "canary without steps raises" true raised
;;

let test_toml_canary_rejects_bad_weight () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.rollout]
strategy = "canary"
steps = [10, 120]
|};
  close_out oc;
  let raised = Result.is_error (Sol_cli_toml.load_result path) in
  Sys.remove path;
  check_bool "invalid canary weight raises" true raised
;;

let test_toml_rejects_malformed () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "replicas = \n";
  close_out oc;
  let raised = Result.is_error (Sol_cli_toml.load_result path) in
  Sys.remove path;
  check_bool "malformed TOML raises Failure" true raised
;;

let test_toml_load_result_validation_error () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.deploy]\nrollout_strategy = \"Blue/Green\"\n";
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { path = _; message }) ->
    assert_contains "typed validation error" message "unsupported rollout_strategy"
  | Ok _ -> Alcotest.fail "expected typed validation error"
  | Error (Sol_cli_toml.Toml_syntax _) ->
    Alcotest.fail "expected validation error, got syntax error"
;;

let test_toml_load_result_syntax_error () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "replicas = \n";
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Toml_syntax { path = _; message }) ->
    assert_contains "typed syntax error" message "sol.toml:"
  | Ok _ -> Alcotest.fail "expected typed syntax error"
  | Error (Sol_cli_toml.Validation _) ->
    Alcotest.fail "expected syntax error, got validation error"
;;

let test_toml_multiline_array_secrets () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.env]
secrets = [
  "DATABASE_URL",
  "API_TOKEN",
]
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  check_bool
    "multi-line secrets array parsed"
    true
    (toml.secret_keys = [ "DATABASE_URL"; "API_TOKEN" ])
;;

let test_toml_dotted_section_headers () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.scale]
replicas = 3
cpu = "250m"
memory = "256Mi"
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  check_bool "replicas from dotted header" true (toml.replicas = Some 3);
  check_bool
    "cpu from dotted header"
    true
    (Option.map Sol_cli_toml.cpu_quantity_to_string toml.cpu = Some "250m");
  check_bool
    "memory from dotted header"
    true
    (Option.map Sol_cli_toml.memory_quantity_to_string toml.memory = Some "256Mi")
;;

let test_toml_canary_pause_steps () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.rollout]
strategy = "canary"
steps = [{weight = 20}, {pause = {}}, {weight = 60}, {pause = {duration = 60}}]
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  match toml.progressive_delivery with
  | Some
      (Sol_cli_toml.Canary
         { steps =
             [ Sol_cli_toml.Weight 20
             ; Sol_cli_toml.Pause None
             ; Sol_cli_toml.Weight 60
             ; Sol_cli_toml.Pause (Some 60)
             ]
         }) -> ()
  | _ -> Alcotest.fail "expected canary steps with pause from [infra.rollout]"
;;

let eso_backend =
  Sol_cli_manifest.External_secrets
    { store_ref = "aws-secrets-manager"
    ; store_kind = "ClusterSecretStore"
    ; key_prefix = "myapp/"
    ; refresh_interval = "1h"
    }
;;

let test_external_secret_doc_no_stringdata () =
  let doc =
    Sol_cli_manifest.external_secret_doc
      ~store_ref:"aws-secrets-manager"
      ~store_kind:"ClusterSecretStore"
      ~key_prefix:"myapp/"
      ~refresh_interval:"1h"
      ~secret_keys:[ "POSTGRES_URL"; "STRIPE_KEY" ]
      ~ns:"myapp-payments"
      ~name:"charge-svc"
    |> render_doc
  in
  assert_contains "kind ExternalSecret" doc "kind: ExternalSecret";
  assert_contains "remoteRef present" doc "remoteRef:";
  assert_contains "ESO apiVersion" doc "apiVersion: external-secrets.io/v1beta1";
  assert_absent "no stringData" doc "stringData"
;;

let test_external_secret_doc_keys_present () =
  let doc =
    Sol_cli_manifest.external_secret_doc
      ~store_ref:"aws-secrets-manager"
      ~store_kind:"ClusterSecretStore"
      ~key_prefix:""
      ~refresh_interval:"1h"
      ~secret_keys:[ "POSTGRES_URL"; "STRIPE_KEY"; "SENDGRID_API_KEY" ]
      ~ns:"myapp-payments"
      ~name:"charge-svc"
    |> render_doc
  in
  assert_contains "POSTGRES_URL secretKey" doc "secretKey: POSTGRES_URL";
  assert_contains "STRIPE_KEY secretKey" doc "secretKey: STRIPE_KEY";
  assert_contains "SENDGRID_API_KEY secretKey" doc "secretKey: SENDGRID_API_KEY"
;;

let test_external_secret_doc_target_name () =
  let doc =
    Sol_cli_manifest.external_secret_doc
      ~store_ref:"my-store"
      ~store_kind:"ClusterSecretStore"
      ~key_prefix:""
      ~refresh_interval:"1h"
      ~secret_keys:[ "POSTGRES_URL" ]
      ~ns:"myapp-payments"
      ~name:"charge-svc"
    |> render_doc
  in
  assert_contains "target name is charge-svc-secrets" doc "name: charge-svc-secrets"
;;

let test_render_spec_eso_backend_no_k8s_secret () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload = render_spec_ok ~secret_backend:eso_backend spec in
  assert_contains "ExternalSecret present" workload "kind: ExternalSecret";
  assert_absent "no plain Secret kind" workload "kind: Secret"
;;

let test_render_spec_eso_backend_all_keys () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload = render_spec_ok ~secret_backend:eso_backend spec in
  assert_contains "POSTGRES_URL in ESO data" workload "secretKey: POSTGRES_URL";
  assert_contains "STRIPE_KEY in ESO data" workload "secretKey: STRIPE_KEY"
;;

let test_render_spec_eso_backend_no_stringdata () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload = render_spec_ok ~secret_backend:eso_backend spec in
  assert_absent "no stringData in ESO output" workload "stringData"
;;

let test_render_spec_k8s_placeholder_default () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "kind Secret present" workload "kind: Secret";
  assert_absent "no ExternalSecret" workload "kind: ExternalSecret"
;;

let test_live_backend_missing_user_secret_returns_error () =
  (try Unix.putenv "MISSING_SECRET_KEY_FOR_TEST" "" with
   | _ -> ());
  Unix.putenv "MISSING_SECRET_KEY_FOR_TEST" "__marker__";
  let spec_with_secret =
    { svc_spec with secrets = [ "MISSING_SECRET_KEY_FOR_TEST", "" ] }
  in
  (match
     Sol_cli_deployment_render.render_spec
       ~workspace:"myapp"
       ~release_id:release_id_of_test
       ~secret_backend:Sol_cli_manifest.Kubernetes_live
       spec_with_secret
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail ("Expected Ok when env var set, got Error: " ^ e));
  Unix.putenv "MISSING_SECRET_KEY_FOR_TEST" "";
  let absent_key = "__SOL_TEST_ABSENT_KEY_XQ9Z2__" in
  let spec_missing = { svc_spec with secrets = [ absent_key, "" ] } in
  match
    Sol_cli_deployment_render.render_spec
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~secret_backend:Sol_cli_manifest.Kubernetes_live
      spec_missing
  with
  | Error msg ->
    check_bool "error mentions the missing key" true (contains msg absent_key)
  | Ok _ -> Alcotest.fail "Expected Error when required secret env var is absent, got Ok"
;;

let test_live_backend_multiple_missing_secrets_all_reported () =
  let absent1 = "__SOL_TEST_ABSENT_A_XQ9Z2__" in
  let absent2 = "__SOL_TEST_ABSENT_B_XQ9Z2__" in
  let spec = { svc_spec with secrets = [ absent1, ""; absent2, "" ] } in
  match
    Sol_cli_deployment_render.render_spec
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~secret_backend:Sol_cli_manifest.Kubernetes_live
      spec
  with
  | Error msg ->
    check_bool "error mentions first absent key" true (contains msg absent1);
    check_bool "error mentions second absent key" true (contains msg absent2)
  | Ok _ ->
    Alcotest.fail "Expected Error when required secret env vars are absent, got Ok"
;;

let test_live_backend_no_user_secrets_always_succeeds () =
  let spec = { svc_spec with secrets = [] } in
  match
    Sol_cli_deployment_render.render_spec
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~secret_backend:Sol_cli_manifest.Kubernetes_live
      spec
  with
  | Ok (_ns, workload) -> assert_contains "kind Secret present" workload "kind: Secret"
  | Error e -> Alcotest.fail ("Expected Ok with no user secrets, got Error: " ^ e)
;;

let assert_k8s_invariants label yaml =
  assert_contains (label ^ ": runAsNonRoot") yaml "runAsNonRoot: true";
  assert_contains
    (label ^ ": allowPrivilegeEscalation")
    yaml
    "allowPrivilegeEscalation: false";
  assert_contains (label ^ ": readOnlyRootFilesystem") yaml "readOnlyRootFilesystem: true"
;;

let test_svc_satisfies_invariants () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_k8s_invariants "svc" workload
;;

let test_worker_satisfies_invariants () =
  let _ns, workload = render_spec_ok worker_spec in
  assert_k8s_invariants "worker" workload
;;

let test_fn_satisfies_invariants () =
  let _ns, workload = render_spec_ok fn_spec in
  assert_k8s_invariants "fn" workload
;;

let test_rollout_canary_satisfies_invariants () =
  let spec =
    { svc_spec with
      progressive_delivery =
        Some
          (Sol_cli_toml.Canary
             { steps = [ Sol_cli_toml.Weight 50; Sol_cli_toml.Weight 100 ] })
    }
  in
  let _ns, workload = render_spec_ok spec in
  assert_k8s_invariants "canary rollout" workload
;;

let test_rollout_blue_green_satisfies_invariants () =
  let spec = { svc_spec with progressive_delivery = Some Sol_cli_toml.Blue_green } in
  let _ns, workload = render_spec_ok spec in
  assert_k8s_invariants "blue-green rollout" workload
;;

let test_gitops_secret_redacted () =
  let spec = { svc_spec with secrets = [ "SECRET_KEY", "real-value-must-not-appear" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  assert_absent
    "no real secret value in gitops output"
    workload
    "real-value-must-not-appear"
;;

let test_shape_http_service_deployment_has_ports () =
  let doc =
    Sol_cli_manifest.deployment_doc
      ~config_hash:"test-hash"
      ~shape:Sol_cli_manifest.Http_service
      ~replicas:1
      ~cpu:"100m"
      ~memory:"128Mi"
      ~ns:"myapp-payments"
      ~name:"charge-svc"
      ~image:"sol-registry:5000/myapp/charge-svc:abc123"
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~domain:"payments"
      ~primitive:"svc"
      ()
    |> render_doc
  in
  assert_contains "Http_service containerPort" doc "containerPort: 8080";
  assert_contains "Http_service readinessProbe" doc "readinessProbe:";
  assert_contains
    "Http_service has prometheus.io/scrape (OBS-011)"
    doc
    "prometheus.io/scrape: \"true\""
;;

let test_shape_background_worker_deployment_has_metrics_port () =
  let doc =
    Sol_cli_manifest.deployment_doc
      ~config_hash:"test-hash"
      ~shape:Sol_cli_manifest.Background_worker
      ~replicas:1
      ~cpu:"100m"
      ~memory:"128Mi"
      ~ns:"myapp-comms"
      ~name:"notify-worker"
      ~image:"sol-registry:5000/myapp/notify-worker:abc123"
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~domain:"comms"
      ~primitive:"worker"
      ()
    |> render_doc
  in
  assert_contains "Background_worker metrics containerPort" doc "containerPort: 9090";
  assert_absent "Background_worker no readinessProbe" doc "readinessProbe:";
  assert_contains
    "Background_worker has prometheus.io/scrape"
    doc
    "prometheus.io/scrape: \"true\"";
  assert_contains "Background_worker scrape port" doc "prometheus.io/port: \"9090\""
;;

let test_shape_rollout_http_service_has_ports () =
  let doc =
    Sol_cli_manifest.rollout_doc
      ~config_hash:"test-hash"
      ~shape:Sol_cli_manifest.Http_service
      ~replicas:1
      ~cpu:"100m"
      ~memory:"128Mi"
      ~ns:"myapp-payments"
      ~name:"charge-svc"
      ~image:"sol-registry:5000/myapp/charge-svc:abc123"
      ~pd:(Sol_cli_toml.Canary { steps = [ Sol_cli_toml.Weight 50 ] })
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~domain:"payments"
      ~primitive:"svc"
      ()
    |> render_doc
  in
  assert_contains "rollout Http_service containerPort" doc "containerPort: 8080";
  assert_contains "rollout Http_service readinessProbe" doc "readinessProbe:"
;;

let test_shape_rollout_background_worker_metrics_port () =
  let doc =
    Sol_cli_manifest.rollout_doc
      ~config_hash:"test-hash"
      ~shape:Sol_cli_manifest.Background_worker
      ~replicas:1
      ~cpu:"100m"
      ~memory:"128Mi"
      ~ns:"myapp-comms"
      ~name:"notify-worker"
      ~image:"sol-registry:5000/myapp/notify-worker:abc123"
      ~pd:(Sol_cli_toml.Canary { steps = [ Sol_cli_toml.Weight 50 ] })
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~domain:"comms"
      ~primitive:"worker"
      ()
    |> render_doc
  in
  assert_contains
    "rollout Background_worker metrics containerPort"
    doc
    "containerPort: 9090";
  assert_contains
    "rollout Background_worker prometheus scrape"
    doc
    "prometheus.io/scrape: \"true\"";
  assert_contains
    "rollout Background_worker prometheus port"
    doc
    "prometheus.io/port: \"9090\"";
  assert_absent "rollout Background_worker no readinessProbe" doc "readinessProbe:"
;;

let test_taxonomy_labels_svc () =
  let _, workload = render_spec_ok svc_spec in
  assert_contains "workspace label" workload {|workspace: "myapp"|};
  assert_contains "domain label" workload {|domain: "payments"|};
  assert_contains "service label" workload {|service: "charge-svc"|};
  assert_contains "primitive label" workload {|primitive: "svc"|};
  assert_contains "release label" workload expected_release_label
;;

let test_taxonomy_labels_worker () =
  let _, workload = render_spec_ok worker_spec in
  assert_contains "workspace label" workload {|workspace: "myapp"|};
  assert_contains "domain label" workload {|domain: "comms"|};
  assert_contains "service label" workload {|service: "notify-worker"|};
  assert_contains "primitive label" workload {|primitive: "worker"|};
  assert_contains "release label" workload expected_release_label
;;

let test_taxonomy_labels_fn () =
  let _, workload = render_spec_ok fn_spec in
  assert_contains "workspace label" workload {|workspace: "myapp"|};
  assert_contains "domain label" workload {|domain: "billing"|};
  assert_contains "service label" workload {|service: "invoice-fn"|};
  assert_contains "primitive label" workload {|primitive: "fn"|};
  assert_contains "release label" workload expected_release_label
;;

let assert_release_label_at_verifier_path label kind workload release_id =
  let _, jsonpath = Sol_cli_rollback.live_resource_and_jsonpath kind in
  let inner = String.sub jsonpath 2 (String.length jsonpath - 3) in
  let depth = List.length (String.split_on_char '.' inner) in
  let expected =
    String.make (2 * (depth - 1)) ' ' ^ {|release: "|} ^ release_id ^ {|"|}
  in
  let release_lines =
    String.split_on_char '\n' workload
    |> List.filter (fun line ->
      let t = String.trim line in
      String.length t >= 8 && String.equal (String.sub t 0 8) "release:")
  in
  Alcotest.(check int) (label ^ ": one release label line") 1 (List.length release_lines);
  Alcotest.(check string)
    (label ^ ": release label sits at the verifier's jsonpath")
    expected
    (List.hd release_lines)
;;

let test_release_label_lives_at_the_verifier_jsonpath () =
  let release_id = Sol_cli_release_id.to_string release_id_of_test in
  let _, svc_workload = render_spec_ok svc_spec in
  assert_release_label_at_verifier_path
    "svc/deployment"
    Sol_cli_rollback.Live_deployment
    svc_workload
    release_id;
  let rollout_spec =
    { svc_spec with
      progressive_delivery =
        Some (Sol_cli_toml.Canary { steps = [ Sol_cli_toml.Weight 50 ] })
    }
  in
  let _, rollout_workload = render_spec_ok rollout_spec in
  assert_release_label_at_verifier_path
    "svc/rollout"
    Sol_cli_rollback.Live_rollout
    rollout_workload
    release_id;
  let _, fn_workload = render_spec_ok fn_spec in
  assert_release_label_at_verifier_path
    "fn/cronjob"
    Sol_cli_rollback.Live_cronjob
    fn_workload
    release_id
;;

let test_taxonomy_labels_match_dashboard_link_normalization () =
  let spec =
    { svc_spec with
      domain = "Payments_Team"
    ; namespace = namespace ~workspace:"Sol_Obs_Review_App" ~domain:"Payments_Team"
    }
  in
  let _, workload = render_spec_ok ~workspace:"Sol_Obs_Review_App" spec in
  assert_contains
    "workspace label matches sol open's normalization"
    workload
    {|workspace: "sol-obs-review-app"|};
  assert_contains
    "domain label matches sol open's normalization"
    workload
    {|domain: "payments-team"|};
  let dashboard_url =
    match
      Sol_cli_open.url
        ~base_url:"http://localhost:3000"
        ~workspace:"Sol_Obs_Review_App"
        ~kind:Sol_cli_open.Dashboard
        (Sol_cli_open.Domain "Payments_Team")
    with
    | Ok url -> url
    | Error msg -> Alcotest.fail msg
  in
  assert_contains
    "dashboard link uses the identical normalized workspace"
    dashboard_url
    "var-workspace=sol-obs-review-app";
  assert_contains
    "dashboard link uses the identical normalized domain"
    dashboard_url
    "var-domain=payments-team"
;;

let test_taxonomy_labels_not_in_selector () =
  let _, workload = render_spec_ok svc_spec in
  assert_contains
    "selector is still exactly app: <name>, nothing else"
    workload
    "matchLabels:\n      app: charge-svc\n  template:"
;;

let test_release_label_is_release_id () =
  let _, workload = render_spec_ok svc_spec in
  assert_contains "release label is the release id" workload expected_release_label
;;

let test_release_label_does_not_leak_image_tag () =
  let spec = { svc_spec with image = "sol-registry:5000/myapp/charge-svc:abc123" } in
  let _, workload = render_spec_ok spec in
  assert_absent "image tag is not the release label" workload {|release: "abc123"|};
  assert_contains
    "image tag still present as the container image"
    workload
    "image: sol-registry:5000/myapp/charge-svc:abc123"
;;

let test_release_label_is_the_supplied_identity () =
  let other =
    Sol_cli_release_id.of_content
      { workspace = "other"; environment = Some "prod"; workloads = [] }
  in
  let _, workload = render_spec_ok ~release_id:other svc_spec in
  assert_contains
    "release label is the supplied id"
    workload
    (Printf.sprintf {|release: "%s"|} (Sol_cli_release_id.to_string other));
  assert_absent "not the default id" workload expected_release_label
;;

let test_sanitize_label_value_bounds_length () =
  let long = String.make 90 'a' in
  check_string
    "truncated to 63 chars"
    (String.make 63 'a')
    (Sol_cli_manifest.sanitize_label_value long)
;;

let test_sanitize_label_value_fixes_trailing_non_alnum () =
  check_string
    "trailing '.' replaced with a safe char"
    "abc0"
    (Sol_cli_manifest.sanitize_label_value "abc.")
;;

let test_sanitize_label_value_no_op_when_already_safe () =
  check_string
    "already-safe value unchanged"
    "payments-team"
    (Sol_cli_manifest.sanitize_label_value "payments-team")
;;

let test_sanitize_label_value_empty_falls_back_to_unknown () =
  check_string
    "empty value -> unknown"
    "unknown"
    (Sol_cli_manifest.sanitize_label_value "")
;;

let test_sanitize_label_value_lowercases_and_replaces_underscores () =
  check_string
    "mixed case + underscores normalized"
    "sol-obs-review-app"
    (Sol_cli_manifest.sanitize_label_value "Sol_Obs_Review_App")
;;

let test_sanitize_label_value_replaces_internal_space () =
  check_string
    "internal space replaced"
    "my-app"
    (Sol_cli_manifest.sanitize_label_value "My App")
;;

let test_sanitize_label_value_strips_leading_non_alnum () =
  check_string
    "leading hyphens stripped"
    "app"
    (Sol_cli_manifest.sanitize_label_value "---app")
;;

let in_temp_workspace f =
  let orig_cwd = Sys.getcwd () in
  let tmpdir = Filename.temp_file "sol-manifest-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Sys.chdir tmpdir;
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir orig_cwd;
      ignore (Sol_cli_fs.remove_tree tmpdir))
    f
;;

let with_charge_svc_workspace f =
  in_temp_workspace
  @@ fun () ->
  let marker = open_out "sol.yml" in
  close_out marker;
  let dir = "app/payments/charge_svc" in
  Result.get_ok (Sol_cli_fs.mkdir_p dir);
  let oc = open_out (Filename.concat dir "Dockerfile") in
  output_string oc "FROM scratch\n";
  close_out oc;
  f ()
;;

let names services = List.map (fun (s : Sol_cli_manifest.service) -> s.name) services

let test_selection_hyphenated_unit_resolves_to_discovered_name () =
  with_charge_svc_workspace
  @@ fun () ->
  let selected =
    match
      Sol_cli_workload_selection.resolve
        ~what:"--scope"
        (Some "payments/charge-svc")
        (Result.get_ok (Sol_cli_manifest.discover_services ()))
    with
    | Ok selected -> selected
    | Error message -> Alcotest.fail message
  in
  Alcotest.(check (list string))
    "hyphenated unit resolves to the discovered name"
    [ "charge_svc" ]
    (names selected.services)
;;

let test_selection_unknown_unit_fails_closed () =
  with_charge_svc_workspace
  @@ fun () ->
  match
    Sol_cli_workload_selection.resolve
      ~what:"--scope"
      (Some "payments/nope")
      (Result.get_ok (Sol_cli_manifest.discover_services ()))
  with
  | Ok _ -> Alcotest.fail "expected a fail-closed resolution"
  | Error message ->
    Alcotest.(check bool) "error names what exists" true (String.length message > 0)
;;

let replace_all haystack needle replacement =
  let hl = String.length haystack
  and nl = String.length needle in
  if nl = 0
  then haystack
  else (
    let out = Buffer.create hl in
    let i = ref 0 in
    while !i <= hl - nl do
      if String.sub haystack !i nl = needle
      then (
        Buffer.add_string out replacement;
        i := !i + nl)
      else (
        Buffer.add_char out haystack.[!i];
        incr i)
    done;
    Buffer.add_string out (String.sub haystack !i (hl - !i));
    Buffer.contents out)
;;

let render_for ?(workspace = "myapp") env spec =
  let ns, workload = render_spec_ok ~workspace ~env spec in
  ns, workload
;;

let resource_names yaml =
  String.split_on_char '\n' yaml
  |> List.filter_map (fun line ->
    let trimmed = String.trim line in
    let prefix = "name:" in
    let plen = String.length prefix in
    if String.length trimmed > plen && String.sub trimmed 0 plen = prefix
    then Some (String.trim (String.sub trimmed plen (String.length trimmed - plen)))
    else None)
;;

let environment_dependent_keys = [ "env"; "SOL_ENV"; "sol.dev/config-hash" ]

let line_key line =
  let trimmed = String.trim line in
  let trimmed =
    if String.length trimmed > 2 && String.sub trimmed 0 2 = "- "
    then String.trim (String.sub trimmed 2 (String.length trimmed - 2))
    else trimmed
  in
  match String.index_opt trimmed ':' with
  | Some i -> String.trim (String.sub trimmed 0 i)
  | None -> trimmed
;;

let values_of_key key yaml =
  String.split_on_char '\n' yaml
  |> List.filter_map (fun line ->
    if line_key line <> key
    then None
    else (
      let trimmed = String.trim line in
      match String.index_opt trimmed ':' with
      | Some i ->
        Some (String.trim (String.sub trimmed (i + 1) (String.length trimmed - i - 1)))
      | None -> None))
;;

let internal_addresses yaml =
  String.split_on_char '\n' yaml
  |> List.filter (fun line -> contains line ".svc.cluster.local")
  |> List.map String.trim
;;

let check_no_unexplained_differences label a b ~env_a ~env_b =
  let la = String.split_on_char '\n' a
  and lb = String.split_on_char '\n' b in
  if List.length la <> List.length lb
  then Alcotest.fail (label ^ ": the two renders differ in line count");
  List.iter2
    (fun x y ->
       if x <> y
       then (
         let key = line_key x in
         if not (List.mem key environment_dependent_keys)
         then
           Alcotest.fail
             (Printf.sprintf
                "%s: this line differs between environments, and only %s may: %s"
                label
                (String.concat ", " environment_dependent_keys)
                (String.trim x));
         if key <> "sol.dev/config-hash"
         then (
           assert_contains label x env_a;
           assert_contains label y env_b;
           check_string
             (label ^ ": " ^ key ^ " carries the environment's name and nothing else")
             (replace_all x env_a "<env>")
             (replace_all y env_b "<env>"))))
    la
    lb
;;

let test_environment_labels_but_does_not_re_address () =
  let ns_alpha, workload_alpha = render_for "alpha" svc_spec in
  let ns_beta, workload_beta = render_for "beta" svc_spec in
  assert_contains "the environment is represented" workload_alpha "alpha";
  assert_contains "the environment is represented" workload_beta "beta";
  check_bool
    "the two environments do not render identically"
    false
    (workload_alpha = workload_beta);
  check_string "the namespace document is identical" ns_alpha ns_beta;
  Alcotest.(check (list string))
    "resource names are identical"
    (resource_names workload_alpha)
    (resource_names workload_beta);
  Alcotest.(check (list string))
    "image references are identical"
    (values_of_key "image" workload_alpha)
    (values_of_key "image" workload_beta);
  Alcotest.(check (list string))
    "internal addresses are identical"
    (internal_addresses workload_alpha)
    (internal_addresses workload_beta);
  check_no_unexplained_differences
    "workload"
    workload_alpha
    workload_beta
    ~env_a:"alpha"
    ~env_b:"beta";
  let ns_again, workload_again = render_for "alpha" svc_spec in
  check_string "the namespace document is stable across renders" ns_alpha ns_again;
  check_string "the workload is stable across renders" workload_alpha workload_again
;;

let test_environment_absent_from_the_namespace () =
  let ns_alpha, _ = render_for "alpha" svc_spec in
  let ns_beta, _ = render_for "beta" svc_spec in
  assert_absent "namespace" ns_alpha "alpha";
  assert_absent "namespace" ns_beta "beta"
;;

let test_worker_sol_env_configmap_present_when_resolved () =
  let _ns, workload = render_spec_ok ~env:"staging" worker_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_contains "worker SOL_ENV config" cm_block {|SOL_ENV: "staging"|}
;;

let test_worker_sol_env_configmap_absent_by_default () =
  let _ns, workload = render_spec_ok worker_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_absent "worker SOL_ENV config" cm_block {|SOL_ENV: |}
;;

let test_fn_sol_env_configmap_present_when_resolved () =
  let _ns, workload = render_spec_ok ~env:"dev" fn_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_contains "fn SOL_ENV config" cm_block {|SOL_ENV: "dev"|}
;;

let test_fn_sol_env_configmap_absent_by_default () =
  let _ns, workload = render_spec_ok fn_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_absent "fn SOL_ENV config" cm_block {|SOL_ENV: |}
;;

let test_fn_render_carries_pushgateway_job () =
  let _, workload = render_spec_ok fn_spec in
  check_bool
    "SOL_PUSHGATEWAY_JOB is <namespace>.<name>"
    true
    (contains
       workload
       (Printf.sprintf
          "SOL_PUSHGATEWAY_JOB: \"%s.%s\""
          (Sol_cli_kubernetes_name.namespace_to_string fn_spec.namespace)
          (Sol_cli_kubernetes_name.k8s_name_to_string fn_spec.k8s_name)))
;;

let test_svc_render_has_no_pushgateway_job () =
  let _, workload = render_spec_ok svc_spec in
  check_bool "svc has no Pushgateway job" false (contains workload "SOL_PUSHGATEWAY_JOB")
;;

let test_fn_without_schedule_is_refused_at_render () =
  match
    Sol_cli_deployment_render.render_spec
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      { fn_spec with schedule = None }
  with
  | Ok _ -> Alcotest.fail "a -fn spec without a schedule must not render hourly"
  | Error msg -> check_bool "names the schedule" true (contains msg "schedule")
;;

let test_local_executor_renders_unverified_jwt_opt_in () =
  let _, workload = render_spec_ok (Sol_cli_executor.local_development_spec svc_spec) in
  check_bool
    "local render carries SOL_ALLOW_UNVERIFIED_JWT=1"
    true
    (contains workload "SOL_ALLOW_UNVERIFIED_JWT: \"1\"")
;;

let test_sol_toml_cannot_set_unverified_jwt_opt_in () =
  let path = Filename.temp_file "sol-toml-optin-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.env]\nconfig = { SOL_ALLOW_UNVERIFIED_JWT = \"1\" }\n";
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    check_bool "names the reserved key" true (contains message "SOL_ALLOW_UNVERIFIED_JWT")
  | Ok _ -> Alcotest.fail "sol.toml must not be able to set SOL_ALLOW_UNVERIFIED_JWT"
  | Error (Sol_cli_toml.Toml_syntax _) -> Alcotest.fail "expected a validation error"
;;

let test_sol_toml_secrets_cannot_name_unverified_jwt_opt_in () =
  let path = Filename.temp_file "sol-toml-optin-secret-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.env]\nsecrets = [\"SOL_ALLOW_UNVERIFIED_JWT\"]\n";
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    check_bool "names the reserved key" true (contains message "SOL_ALLOW_UNVERIFIED_JWT")
  | Ok _ -> Alcotest.fail "a sol.toml secret must not be able to carry the opt-in"
  | Error (Sol_cli_toml.Toml_syntax _) -> Alcotest.fail "expected a validation error"
;;

let test_sol_secret_rejects_unverified_jwt_opt_in () =
  check_bool
    "sol secret set refuses the reserved key"
    true
    (Result.is_error (Sol_cli_secret.validate_key "SOL_ALLOW_UNVERIFIED_JWT"))
;;

let test_sol_secret_delete_accepts_reserved_key_format () =
  check_bool
    "sol secret delete may remove the reserved key"
    true
    (Result.is_ok (Sol_cli_secret.validate_key_format "SOL_ALLOW_UNVERIFIED_JWT"))
;;

let test_deploy_render_has_no_unverified_jwt_opt_in () =
  let _, workload = render_spec_ok svc_spec in
  check_bool
    "a deploy/GitOps render never carries the opt-in"
    false
    (contains workload "SOL_ALLOW_UNVERIFIED_JWT")
;;

let test_svc_readiness_probe_uses_readyz () =
  let _, workload =
    render_spec_ok { svc_spec with language = Some Sol_cli_compat.Ocaml }
  in
  check_bool
    "readinessProbe path is /readyz"
    true
    (contains workload "readinessProbe:\n          httpGet:\n            path: /readyz");
  check_bool
    "livenessProbe path is /healthz"
    true
    (contains workload "livenessProbe:\n          httpGet:\n            path: /healthz")
;;

let test_undeclared_language_readiness_stays_on_healthz () =
  let _, workload = render_spec_ok { svc_spec with language = None } in
  check_bool
    "undeclared-language readinessProbe path is /healthz"
    true
    (contains workload "readinessProbe:\n          httpGet:\n            path: /healthz")
;;

let test_ts_svc_readiness_stays_on_healthz () =
  let _, workload =
    render_spec_ok { svc_spec with language = Some Sol_cli_compat.Typescript }
  in
  check_bool
    "TypeScript readinessProbe path is /healthz"
    true
    (contains workload "readinessProbe:\n          httpGet:\n            path: /healthz")
;;

let parse_documents text =
  text
  |> String.split_on_char '\n'
  |> List.fold_left
       (fun (docs, current) line ->
          if line = "---" then List.rev current :: docs, [] else docs, line :: current)
       ([], [])
  |> (fun (docs, current) -> List.rev (List.rev current :: docs))
  |> List.map (String.concat "\n")
  |> List.filter (fun doc -> String.trim doc <> "")
  |> List.map (fun doc ->
    match Yaml.of_string doc with
    | Ok v -> v
    | Error (`Msg m) -> Alcotest.failf "rendered document does not parse: %s\n%s" m doc)
;;

let rec lookup path (v : Yaml.value) =
  match path, v with
  | [], v -> Some v
  | key :: rest, `O members -> Option.bind (List.assoc_opt key members) (lookup rest)
  | _ -> None
;;

let find_kind kind docs =
  match List.find_opt (fun d -> lookup [ "kind" ] d = Some (`String kind)) docs with
  | Some d -> d
  | None -> Alcotest.failf "no %s document" kind
;;

let test_hostile_values_round_trip () =
  let hostile = "a \"quoted\" \\ value\n  INJECTED: \"yes\"\n# and: more" in
  let spec =
    { svc_spec with
      config = [ "APP_NOTE", hostile; "APP_FLAG", "true"; "APP_VERSION", "1.10" ]
    ; extra_labels = [ "team", "yes" ]
    }
  in
  let _ns, workload = render_spec_ok spec in
  let docs = parse_documents workload in
  let configmap = find_kind "ConfigMap" docs in
  [ "APP_NOTE", hostile; "APP_FLAG", "true"; "APP_VERSION", "1.10" ]
  |> List.iter (fun (key, expected) ->
    Alcotest.(check (option string))
      ("ConfigMap " ^ key)
      (Some expected)
      (match lookup [ "data"; key ] configmap with
       | Some (`String s) -> Some s
       | _ -> None));
  Alcotest.(check bool)
    "no injected key"
    true
    (lookup [ "data"; "INJECTED" ] configmap = None);
  let deployment = find_kind "Deployment" docs in
  Alcotest.(check bool)
    "a label that YAML 1.1 reads as a boolean stays a string"
    true
    (lookup [ "spec"; "template"; "metadata"; "labels"; "team" ] deployment
     = Some (`String "yes"))
;;

let () =
  Alcotest.run
    "manifest_render"
    [ ( "values are written exactly (REFAC-131)"
      , [ Alcotest.test_case
            "hostile env and label values round-trip"
            `Quick
            test_hostile_values_round_trip
        ] )
    ; ( "fn Pushgateway job and schedule (BUG-048)"
      , [ Alcotest.test_case
            "fn carries SOL_PUSHGATEWAY_JOB"
            `Quick
            test_fn_render_carries_pushgateway_job
        ; Alcotest.test_case "svc does not" `Quick test_svc_render_has_no_pushgateway_job
        ; Alcotest.test_case
            "fn without schedule refused"
            `Quick
            test_fn_without_schedule_is_refused_at_render
        ] )
    ; ( "unverified JWT opt-in (SEC-006)"
      , [ Alcotest.test_case
            "local executor renders it"
            `Quick
            test_local_executor_renders_unverified_jwt_opt_in
        ; Alcotest.test_case
            "deploy render does not"
            `Quick
            test_deploy_render_has_no_unverified_jwt_opt_in
        ; Alcotest.test_case
            "sol.toml cannot set it"
            `Quick
            test_sol_toml_cannot_set_unverified_jwt_opt_in
        ; Alcotest.test_case
            "sol.toml secrets cannot name it"
            `Quick
            test_sol_toml_secrets_cannot_name_unverified_jwt_opt_in
        ; Alcotest.test_case
            "sol secret set refuses it"
            `Quick
            test_sol_secret_rejects_unverified_jwt_opt_in
        ; Alcotest.test_case
            "sol secret delete can still remove it"
            `Quick
            test_sol_secret_delete_accepts_reserved_key_format
        ] )
    ; ( "svc readiness (INFRA-073)"
      , [ Alcotest.test_case
            "readiness uses /readyz"
            `Quick
            test_svc_readiness_probe_uses_readyz
        ; Alcotest.test_case
            "TypeScript stays on /healthz"
            `Quick
            test_ts_svc_readiness_stays_on_healthz
        ; Alcotest.test_case
            "undeclared language stays on /healthz"
            `Quick
            test_undeclared_language_readiness_stays_on_healthz
        ] )
    ; ( "SOL_ENV reaches every primitive"
      , [ Alcotest.test_case
            "worker SOL_ENV when resolved"
            `Quick
            test_worker_sol_env_configmap_present_when_resolved
        ; Alcotest.test_case
            "worker SOL_ENV absent by default"
            `Quick
            test_worker_sol_env_configmap_absent_by_default
        ; Alcotest.test_case
            "fn SOL_ENV when resolved"
            `Quick
            test_fn_sol_env_configmap_present_when_resolved
        ; Alcotest.test_case
            "fn SOL_ENV absent by default"
            `Quick
            test_fn_sol_env_configmap_absent_by_default
        ] )
    ; ( "svc"
      , [ Alcotest.test_case "namespace yaml" `Quick test_svc_namespace
        ; Alcotest.test_case "persistent volume claim + mount" `Quick test_svc_volumes
        ; Alcotest.test_case "deployment name" `Quick test_svc_deployment_name
        ; Alcotest.test_case "image" `Quick test_svc_image
        ; Alcotest.test_case "has Service resource" `Quick test_svc_has_service_resource
        ; Alcotest.test_case "has Ingress" `Quick test_svc_has_ingress
        ; Alcotest.test_case
            "NetworkPolicy allows monitoring ingress"
            `Quick
            test_svc_networkpolicy_allows_monitoring_ingress
        ; Alcotest.test_case
            "calls peer env and NetworkPolicy"
            `Quick
            test_svc_calls_peer_env_and_network_policy
        ; Alcotest.test_case "has containerPort" `Quick test_svc_has_ports
        ; Alcotest.test_case "replicas from spec" `Quick test_svc_replicas
        ; Alcotest.test_case
            "default resources (replicas/cpu/memory)"
            `Quick
            test_svc_default_resources
        ; Alcotest.test_case "extra config in map" `Quick test_svc_extra_config
        ; Alcotest.test_case
            "env label when resolved"
            `Quick
            test_svc_env_label_present_when_resolved
        ; Alcotest.test_case
            "env label absent by default"
            `Quick
            test_svc_env_label_absent_by_default
        ; Alcotest.test_case
            "SOL_ENV config when resolved"
            `Quick
            test_svc_sol_env_configmap_present_when_resolved
        ; Alcotest.test_case
            "SOL_ENV config absent by default"
            `Quick
            test_svc_sol_env_configmap_absent_by_default
        ; Alcotest.test_case
            "SOL_ENV config uses target"
            `Quick
            test_svc_sol_env_configmap_target_overrides_config
        ; Alcotest.test_case "default postgres url" `Quick test_svc_default_postgres_url
        ; Alcotest.test_case
            "POSTGRES_URL not in ConfigMap"
            `Quick
            test_postgres_url_not_in_configmap
        ; Alcotest.test_case "POSTGRES_URL in Secret" `Quick test_postgres_url_in_secret
        ; Alcotest.test_case
            "POSTGRES_URL env in live Secret"
            `Quick
            test_live_secret_uses_postgres_url_env
        ; Alcotest.test_case
            "default redpanda admin"
            `Quick
            test_svc_default_redpanda_admin_url
        ; Alcotest.test_case
            "svc declares KAFKA_SECURITY_PROTOCOL"
            `Quick
            test_svc_declares_kafka_security_protocol
        ; Alcotest.test_case
            "secret refs no values"
            `Quick
            test_svc_secret_refs_without_values
        ; Alcotest.test_case "namespace in workload" `Quick test_svc_namespace_in_workload
        ; Alcotest.test_case "image override (up dry-run)" `Quick test_svc_image_override
        ; Alcotest.test_case
            "user secret key in Secret resource"
            `Quick
            test_user_secret_key_in_secret_resource
        ; Alcotest.test_case
            "user secret key ref in Deployment"
            `Quick
            test_user_secret_key_ref_in_deployment
        ; Alcotest.test_case
            "multiple user secret keys in Secret"
            `Quick
            test_multiple_user_secret_keys_in_secret_resource
        ; Alcotest.test_case
            "default secrets preserved with user secrets"
            `Quick
            test_default_secrets_preserved_with_user_secrets
        ; Alcotest.test_case
            "GitOps redacts secret values"
            `Quick
            test_gitops_redacts_all_secret_values
        ] )
    ; ( "worker"
      , [ Alcotest.test_case "namespace yaml" `Quick test_worker_namespace
        ; Alcotest.test_case "persistent volume claim + mount" `Quick test_worker_volumes
        ; Alcotest.test_case "image" `Quick test_worker_image
        ; Alcotest.test_case "no Service/Ingress" `Quick test_worker_no_service_resource
        ; Alcotest.test_case "metrics containerPort" `Quick test_worker_metrics_port
        ; Alcotest.test_case "has Deployment" `Quick test_worker_has_deployment
        ; Alcotest.test_case
            "ServiceAccount disables token automount"
            `Quick
            test_service_account_disables_token_automount
        ; Alcotest.test_case
            "svc ServiceAccount disables token automount"
            `Quick
            test_svc_service_account_disables_token_automount
        ; Alcotest.test_case
            "fn ServiceAccount disables token automount"
            `Quick
            test_fn_service_account_disables_token_automount
        ; Alcotest.test_case
            "explicit termination grace"
            `Quick
            test_termination_grace_is_explicit
        ; Alcotest.test_case "consumer probes" `Quick test_worker_consumer_probes
        ; Alcotest.test_case
            "non-consumer worker has no liveness"
            `Quick
            test_non_consumer_worker_has_no_liveness
        ; Alcotest.test_case
            "node-failure-tolerant renders PDB and spread"
            `Quick
            test_node_failure_tolerant_renders_pdb_and_spread
        ; Alcotest.test_case "single has no PDB" `Quick test_single_has_no_pdb
        ; Alcotest.test_case
            "user secret key in Secret resource"
            `Quick
            test_worker_user_secret_key_in_secret_resource
        ; Alcotest.test_case
            "env label when resolved"
            `Quick
            test_worker_env_label_present_when_resolved
        ] )
    ; ( "fn"
      , [ Alcotest.test_case "namespace yaml" `Quick test_fn_namespace
        ; Alcotest.test_case "image" `Quick test_fn_image
        ; Alcotest.test_case "kind CronJob" `Quick test_fn_cronjob
        ; Alcotest.test_case "schedule from spec" `Quick test_fn_schedule
        ; Alcotest.test_case
            "env label when resolved"
            `Quick
            test_fn_env_label_present_when_resolved
        ; Alcotest.test_case "no Deployment" `Quick test_fn_no_deployment
        ; Alcotest.test_case
            "user secret key in Secret resource"
            `Quick
            test_fn_user_secret_key_in_secret_resource
        ; Alcotest.test_case
            "pod template has app label (AUDIT-040)"
            `Quick
            test_fn_cronjob_pod_template_has_app_label
        ; Alcotest.test_case
            "cpu/memory configurable (BUG-031)"
            `Quick
            test_fn_cpu_memory_configurable
        ; Alcotest.test_case
            "cpu/memory request equals limit (BUG-031)"
            `Quick
            test_fn_cpu_memory_request_equals_limit
        ; Alcotest.test_case
            "scheduled_concurrency configurable (FEAT-079)"
            `Quick
            test_fn_scheduled_concurrency_configurable
        ; Alcotest.test_case
            "scheduled_concurrency default is Allow (FEAT-079)"
            `Quick
            test_fn_scheduled_concurrency_default_is_allow
        ; Alcotest.test_case
            "backoff_limit configurable (FEAT-079)"
            `Quick
            test_fn_backoff_limit_configurable
        ; Alcotest.test_case
            "backoff_limit default is 3 (FEAT-079)"
            `Quick
            test_fn_backoff_limit_default_is_three
        ] )
    ; ( "escape_hatches"
      , [ Alcotest.test_case "rollout Recreate" `Quick test_rollout_recreate
        ; Alcotest.test_case "rollout RollingUpdate" `Quick test_rollout_rolling_update
        ; Alcotest.test_case
            "rollout default=RollingUpdate"
            `Quick
            test_rollout_default_is_rolling_update
        ; Alcotest.test_case
            "progressive default Deployment"
            `Quick
            test_progressive_default_is_deployment
        ; Alcotest.test_case
            "progressive canary Rollout"
            `Quick
            test_progressive_canary_rollout
        ; Alcotest.test_case
            "progressive worker canary"
            `Quick
            test_progressive_canary_worker_no_service
        ; Alcotest.test_case
            "progressive blue-green Rollout"
            `Quick
            test_progressive_blue_green_rollout
        ; Alcotest.test_case
            "rollout canary secrets use name-secrets"
            `Quick
            test_rollout_canary_secrets_use_sol_secrets
        ; Alcotest.test_case
            "rollout blue-green secrets use name-secrets"
            `Quick
            test_rollout_blue_green_secrets_use_sol_secrets
        ; Alcotest.test_case "ingress host override" `Quick test_ingress_host_override
        ; Alcotest.test_case
            "undeclared ingress_host gets a dev host"
            `Quick
            test_undeclared_ingress_host_gets_dev_host
        ; Alcotest.test_case
            "blue-green ingress tls secret matches plan"
            `Quick
            test_blue_green_ingress_tls_secret_matches_plan
        ; Alcotest.test_case "ingress path override" `Quick test_ingress_path_override
        ; Alcotest.test_case "ingress default path" `Quick test_ingress_default_path
        ; Alcotest.test_case
            "extra_labels in pod template"
            `Quick
            test_extra_labels_appear_in_pod_template
        ; Alcotest.test_case
            "extra_labels empty default"
            `Quick
            test_extra_labels_empty_by_default
        ; Alcotest.test_case
            "invalid rollout_strategy"
            `Quick
            test_toml_invalid_rollout_strategy
        ; Alcotest.test_case
            "reserved label key rejected"
            `Quick
            test_toml_reserved_label_key
        ; Alcotest.test_case
            "valid Recreate from toml"
            `Quick
            test_toml_valid_rollout_recreate
        ; Alcotest.test_case
            "valid ingress overrides toml"
            `Quick
            test_toml_valid_ingress_overrides
        ; Alcotest.test_case
            "valid service calls toml"
            `Quick
            test_toml_valid_service_calls
        ; Alcotest.test_case "invalid cpu quantity" `Quick test_toml_invalid_cpu_quantity
        ; Alcotest.test_case
            "invalid memory quantity"
            `Quick
            test_toml_invalid_memory_quantity
        ; Alcotest.test_case "invalid ingress host" `Quick test_toml_invalid_ingress_host
        ; Alcotest.test_case "invalid ingress path" `Quick test_toml_invalid_ingress_path
        ; Alcotest.test_case "secret keys from toml" `Quick test_toml_secret_keys
        ; Alcotest.test_case
            "valid canary rollout toml"
            `Quick
            test_toml_valid_canary_rollout
        ; Alcotest.test_case
            "valid blue-green rollout toml"
            `Quick
            test_toml_valid_blue_green_rollout
        ; Alcotest.test_case
            "invalid progressive strategy"
            `Quick
            test_toml_invalid_progressive_strategy
        ; Alcotest.test_case
            "canary requires steps"
            `Quick
            test_toml_canary_requires_steps
        ; Alcotest.test_case
            "canary rejects bad weight"
            `Quick
            test_toml_canary_rejects_bad_weight
        ; Alcotest.test_case "malformed TOML raises" `Quick test_toml_rejects_malformed
        ; Alcotest.test_case
            "load_result validation error"
            `Quick
            test_toml_load_result_validation_error
        ; Alcotest.test_case
            "load_result syntax error"
            `Quick
            test_toml_load_result_syntax_error
        ; Alcotest.test_case
            "multi-line secrets array"
            `Quick
            test_toml_multiline_array_secrets
        ; Alcotest.test_case
            "dotted section headers"
            `Quick
            test_toml_dotted_section_headers
        ; Alcotest.test_case "canary pause steps" `Quick test_toml_canary_pause_steps
        ] )
    ; ( "external_secrets"
      , [ Alcotest.test_case
            "external_secret_doc: no stringData"
            `Quick
            test_external_secret_doc_no_stringdata
        ; Alcotest.test_case
            "external_secret_doc: keys present"
            `Quick
            test_external_secret_doc_keys_present
        ; Alcotest.test_case
            "external_secret_doc: target name"
            `Quick
            test_external_secret_doc_target_name
        ; Alcotest.test_case
            "render_spec ESO: no k8s Secret"
            `Quick
            test_render_spec_eso_backend_no_k8s_secret
        ; Alcotest.test_case
            "render_spec ESO: all keys in data"
            `Quick
            test_render_spec_eso_backend_all_keys
        ; Alcotest.test_case
            "render_spec ESO: no stringData"
            `Quick
            test_render_spec_eso_backend_no_stringdata
        ; Alcotest.test_case
            "render_spec default: k8s placeholder"
            `Quick
            test_render_spec_k8s_placeholder_default
        ] )
    ; ( "config_parsing_policy"
      , [ Alcotest.test_case
            "live: missing user secret → Error"
            `Quick
            test_live_backend_missing_user_secret_returns_error
        ; Alcotest.test_case
            "live: multiple missing secrets all reported"
            `Quick
            test_live_backend_multiple_missing_secrets_all_reported
        ; Alcotest.test_case
            "live: no user secrets → always Ok"
            `Quick
            test_live_backend_no_user_secrets_always_succeeds
        ] )
    ; ( "workload_shape"
      , [ Alcotest.test_case
            "Http_service deployment has ports"
            `Quick
            test_shape_http_service_deployment_has_ports
        ; Alcotest.test_case
            "Background_worker deployment metrics port"
            `Quick
            test_shape_background_worker_deployment_has_metrics_port
        ; Alcotest.test_case
            "Http_service rollout has ports"
            `Quick
            test_shape_rollout_http_service_has_ports
        ; Alcotest.test_case
            "Background_worker rollout metrics port"
            `Quick
            test_shape_rollout_background_worker_metrics_port
        ] )
    ; ( "artifact_invariants"
      , [ Alcotest.test_case
            "svc satisfies security invariants"
            `Quick
            test_svc_satisfies_invariants
        ; Alcotest.test_case
            "worker satisfies security invariants"
            `Quick
            test_worker_satisfies_invariants
        ; Alcotest.test_case
            "fn satisfies security invariants"
            `Quick
            test_fn_satisfies_invariants
        ; Alcotest.test_case
            "canary rollout satisfies security invariants"
            `Quick
            test_rollout_canary_satisfies_invariants
        ; Alcotest.test_case
            "blue-green rollout satisfies security invariants"
            `Quick
            test_rollout_blue_green_satisfies_invariants
        ; Alcotest.test_case
            "GitOps mode redacts secret values"
            `Quick
            test_gitops_secret_redacted
        ] )
    ; ( "taxonomy_labels"
      , [ Alcotest.test_case "svc" `Quick test_taxonomy_labels_svc
        ; Alcotest.test_case "worker" `Quick test_taxonomy_labels_worker
        ; Alcotest.test_case "fn" `Quick test_taxonomy_labels_fn
        ; Alcotest.test_case
            "release label sits at the verifier's jsonpath"
            `Quick
            test_release_label_lives_at_the_verifier_jsonpath
        ; Alcotest.test_case "not in selector" `Quick test_taxonomy_labels_not_in_selector
        ; Alcotest.test_case
            "matches sol open dashboard link normalization"
            `Quick
            test_taxonomy_labels_match_dashboard_link_normalization
        ; Alcotest.test_case
            "label is the release id"
            `Quick
            test_release_label_is_release_id
        ; Alcotest.test_case
            "label does not leak the image tag"
            `Quick
            test_release_label_does_not_leak_image_tag
        ; Alcotest.test_case
            "label is the supplied identity"
            `Quick
            test_release_label_is_the_supplied_identity
        ; Alcotest.test_case
            "sanitize_label_value bounds length"
            `Quick
            test_sanitize_label_value_bounds_length
        ; Alcotest.test_case
            "sanitize_label_value fixes trailing non-alnum"
            `Quick
            test_sanitize_label_value_fixes_trailing_non_alnum
        ; Alcotest.test_case
            "sanitize_label_value no-op when already safe"
            `Quick
            test_sanitize_label_value_no_op_when_already_safe
        ; Alcotest.test_case
            "sanitize_label_value empty -> unknown"
            `Quick
            test_sanitize_label_value_empty_falls_back_to_unknown
        ; Alcotest.test_case
            "sanitize_label_value lowercases + replaces underscores"
            `Quick
            test_sanitize_label_value_lowercases_and_replaces_underscores
        ; Alcotest.test_case
            "sanitize_label_value replaces internal space"
            `Quick
            test_sanitize_label_value_replaces_internal_space
        ; Alcotest.test_case
            "sanitize_label_value strips leading non-alnum"
            `Quick
            test_sanitize_label_value_strips_leading_non_alnum
        ] )
    ; ( "workload_selection"
      , [ Alcotest.test_case
            "hyphenated unit resolves to discovered name"
            `Quick
            test_selection_hyphenated_unit_resolves_to_discovered_name
        ; Alcotest.test_case
            "unknown unit fails closed"
            `Quick
            test_selection_unknown_unit_fails_closed
        ] )
    ; ( "environment"
      , [ Alcotest.test_case
            "an environment labels but does not re-address"
            `Quick
            test_environment_labels_but_does_not_re_address
        ; Alcotest.test_case
            "an environment is absent from the namespace"
            `Quick
            test_environment_absent_from_the_namespace
        ] )
    ]
;;
