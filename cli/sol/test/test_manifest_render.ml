(* Regression tests for Sol_cli_deployment_render.render_spec.
   Constructs service_spec values directly (no filesystem required) and checks
   that the rendered YAML contains the expected resource names, image
   references, namespaces, and primitive-specific resources. *)

let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

(** Unwrap a [render_spec] result, failing the test on [Error]. *)
let render_spec_ok ?(workspace = "myapp") ?env ?image ?secret_backend spec =
  match
    Sol_cli_deployment_render.render_spec ~workspace ?env ?image ?secret_backend spec
  with
  | Ok v -> v
  | Error e -> Alcotest.fail ("render_spec unexpectedly failed: " ^ e)
;;

(* ── helpers ─────────────────────────────────────────────────────────────── *)

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

let contains haystack needle =
  let hl = String.length haystack
  and nl = String.length needle in
  if nl = 0
  then true
  else if nl > hl
  then false
  else (
    let found = ref false in
    for i = 0 to hl - nl do
      if (not !found) && String.sub haystack i nl = needle then found := true
    done;
    !found)
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
  Sol_cli_deployment_plan.namespace_of_exn ~workspace ~domain
;;

(* Extract the YAML document block that contains [kind_marker] (e.g. "kind: ConfigMap").
   Splits the full YAML on "---" separators and returns the first block that
   contains the marker, or the empty string if none is found. *)
let extract_kind_block yaml kind_marker =
  (* Split on "\n---" or start-of-string "---" boundaries *)
  let sep = "\n---" in
  let sl = String.length sep in
  let yl = String.length yaml in
  let blocks = ref [] in
  let start = ref 0 in
  for i = 0 to yl - sl do
    if String.sub yaml i sl = sep
    then (
      blocks := String.sub yaml !start (i - !start) :: !blocks;
      start := i + 1 (* keep the "---" at the start of the next block *))
  done;
  blocks := String.sub yaml !start (yl - !start) :: !blocks;
  let result = ref "" in
  List.iter
    (fun b -> if !result = "" && contains b kind_marker then result := b)
    (List.rev !blocks);
  !result
;;

(* ── fixtures ────────────────────────────────────────────────────────────── *)

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
  ; replicas = 2
  ; cpu = cpu "200m"
  ; memory = memory "256Mi"
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
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
  ; source_dir = "app/comms/notify_worker"
  ; image = "sol-registry:5000/myapp/notify-worker:abc123"
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

(* ── volume tests ────────────────────────────────────────────────────────── *)

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

(* ── Svc tests ───────────────────────────────────────────────────────────── *)

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
  (* "kind: Service\n" matches the Service resource, not ServiceAccount *)
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc Service resource" workload "kind: Service\n"
;;

let test_svc_has_ingress () =
  let _ns, workload = render_spec_ok svc_spec in
  let ingress_block = extract_kind_block workload "kind: Ingress" in
  assert_contains "svc Ingress resource" workload "kind: Ingress";
  (* FEAT-042: pin the class explicitly. k3s/k3d ships Traefik as its own
     IngressClass, so a classless Ingress is claimed by Traefik locally and by
     nothing once ingress-nginx's class is not the cluster default. `nginx`
     matches cli/platform/infra/base's own `ingress_class_name`. *)
  assert_contains
    "ingress pins the nginx IngressClass"
    ingress_block
    "ingressClassName: nginx"
;;

(* Regression test: the NetworkPolicy's egress already allowed pods to reach
   Prometheus/Loki/Tempo in the monitoring namespace, but ingress had no
   matching allowance -- Prometheus's own scrape requests into the pod were
   silently dropped, so every freshly-deployed service's metrics panel (and
   any dashboard template variable backed by those labels) stayed empty
   with no error anywhere in the chain. Confirmed live against a real k3d
   cluster: wget from Prometheus's own pod to the target pod's IP got
   "connection refused" on the exact port kubelet's own probes and
   `sol status`'s port-forward could reach fine -- the NetworkPolicy, not
   the app, was the blocker. *)
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

let test_svc_has_ports () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc containerPort" workload "containerPort: 8080"
;;

let test_svc_replicas () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc replicas=2" workload "replicas: 2"
;;

(* CODE_LAYER-009: svc_spec above uses non-default replicas/cpu/memory so
   test_svc_replicas has something to assert against; nothing else in this
   file exercises render_spec's defaults (replicas=1, cpu=100m, memory=128Mi
   — see Sol_cli_deployment_plan's Option.value ~default:... plan-building)
   end to end. This was previously covered incidentally by a parity test
   against the (now-deleted) legacy render path. *)
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

(* FEAT-026: sol deploy's resolved target's env is threaded through to a
   real env taxonomy label — omitted (not a fake default) when no target
   resolved one, e.g. sol up. *)
let test_svc_env_label_present_when_resolved () =
  let _ns, workload = render_spec_ok ~env:"prod" svc_spec in
  assert_contains "svc env label" workload {|env: "prod"|}
;;

let test_svc_env_label_absent_by_default () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_absent "svc env label" workload {|env: "|}
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
  (* POSTGRES_URL must be in the Secret with an empty value (no hardcoded cred) *)
  let _ns, workload = render_spec_ok svc_spec in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "svc default postgres url in secret" secret_block {|POSTGRES_URL: ""|}
;;

let test_postgres_url_not_in_configmap () =
  (* POSTGRES_URL must never appear in the ConfigMap — it contains an embedded password *)
  let _ns, workload = render_spec_ok svc_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_absent "POSTGRES_URL absent from ConfigMap" cm_block "POSTGRES_URL"
;;

let test_postgres_url_in_secret () =
  (* A Secret resource must be emitted and must contain POSTGRES_URL in stringData with empty value *)
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "Secret resource present" workload "kind: Secret";
  assert_contains "stringData section" workload "stringData:";
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "POSTGRES_URL in stringData" secret_block {|POSTGRES_URL: ""|}
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

let test_svc_secret_refs_without_values () =
  (* Use Kubernetes_placeholder so the test does not require DATABASE_URL and
     API_TOKEN to be set in the environment.  We are checking for structural
     YAML (key refs in the Deployment, no values), not live env-var reading. *)
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

(* ── AUDIT-016: user-defined secret_keys emitted as Secret resource ───────── *)

(* When secrets = [("STRIPE_KEY", "")] the rendered workload must include a
   Secret resource (kind: Secret) that carries STRIPE_KEY in its stringData
   section.  The value is empty — operators fill it in at apply time. *)
let test_user_secret_key_in_secret_resource () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "STRIPE_KEY present in Secret resource" secret_block "STRIPE_KEY:"
;;

(* The key reference in the Deployment env block must also be present. *)
let test_user_secret_key_ref_in_deployment () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  assert_contains "STRIPE_KEY secretKeyRef" workload "key: STRIPE_KEY"
;;

(* Multiple user-defined secret keys must all appear in the Secret resource. *)
let test_multiple_user_secret_keys_in_secret_resource () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", ""; "SENDGRID_API_KEY", "" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "STRIPE_KEY in Secret" secret_block "STRIPE_KEY:";
  assert_contains "SENDGRID_API_KEY in Secret" secret_block "SENDGRID_API_KEY:"
;;

(* The default POSTGRES_URL must still be present alongside user secrets. *)
let test_default_secrets_preserved_with_user_secrets () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "POSTGRES_URL still in Secret" secret_block "POSTGRES_URL:";
  assert_contains "STRIPE_KEY also in Secret" secret_block "STRIPE_KEY:"
;;

(* GitOps output must carry the required secret keys but no values. *)
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

(* Worker with secret_keys also emits Secret resource with those keys. *)
let test_worker_user_secret_key_in_secret_resource () =
  let spec = { worker_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "worker STRIPE_KEY in Secret" secret_block "STRIPE_KEY:"
;;

(* Fn/CronJob with secret_keys also emits Secret resource with those keys. *)
let test_fn_user_secret_key_in_secret_resource () =
  let spec = { fn_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "fn STRIPE_KEY in Secret" secret_block "STRIPE_KEY:"
;;

(* image override: dry-run uses push_image *)
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

(* ── Worker tests ────────────────────────────────────────────────────────── *)

let test_worker_namespace () =
  let ns_yaml, _ = render_spec_ok worker_spec in
  assert_contains "worker ns" ns_yaml "name: myapp-comms"
;;

let test_worker_image () =
  let _ns, workload = render_spec_ok worker_spec in
  assert_contains "worker image" workload "sol-registry:5000/myapp/notify-worker:abc123"
;;

let test_worker_no_service_resource () =
  (* Workers don't expose HTTP — no Service or Ingress resource.
     Check for "kind: Service\n" to avoid matching "kind: ServiceAccount". *)
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

(* ── Fn tests ────────────────────────────────────────────────────────────── *)

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

let test_fn_default_schedule () =
  (* When schedule=None the default cron expression is used *)
  let spec = { fn_spec with schedule = None } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "fn default schedule" workload {|schedule: "0 * * * *"|}
;;

(* AUDIT-040: CronJob pod template must carry app: <k8s_name> so that the
   generated NetworkPolicy (which selects on app: <name>) matches fn pods. *)
let test_fn_cronjob_pod_template_has_app_label () =
  let _ns, workload = render_spec_ok fn_spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  assert_contains "fn cronjob pod template app label" cronjob_block "app: invoice-fn"
;;

(* ── Escape-hatch tests ──────────────────────────────────────────────────── *)

let test_rollout_recreate () =
  (* rollout_strategy = Recreate must produce "type: Recreate" in the Deployment spec *)
  let spec = { svc_spec with rollout_strategy = Some Sol_cli_toml.Recreate } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "recreate strategy" workload "type: Recreate";
  assert_absent "no RollingUpdate" workload "type: RollingUpdate"
;;

let test_rollout_rolling_update () =
  (* rollout_strategy = RollingUpdate (explicit) must produce "type: RollingUpdate" *)
  let spec = { svc_spec with rollout_strategy = Some Sol_cli_toml.RollingUpdate } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "rolling strategy" workload "type: RollingUpdate";
  assert_absent "no Recreate" workload "type: Recreate"
;;

let test_rollout_default_is_rolling_update () =
  (* Default (None) must also produce RollingUpdate *)
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

(* ── AUDIT-039: Argo Rollout uses <name>-secrets, not sol-secrets ─────────── *)

(* Canary Rollout with secrets must reference charge-svc-secrets (not sol-secrets)
   in the secretKeyRef block. *)
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

(* Blue-green Rollout with secrets must also reference charge-svc-secrets. *)
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

let test_hostless_ingress_has_no_tls_redirect () =
  let _ns, workload = render_spec_ok svc_spec in
  let ingress_block = extract_kind_block workload "kind: Ingress" in
  assert_contains "hostless http rule" ingress_block "  - http:";
  assert_absent "hostless no issuer" ingress_block "cert-manager.io/cluster-issuer";
  assert_absent "hostless no ssl redirect" ingress_block "ssl-redirect";
  assert_absent "hostless no tls" ingress_block "tls:"
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
  (* ingress_path override must appear in the path field *)
  let spec = { svc_spec with ingress_path = Some (ingress_path "/api/v2") } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "ingress path" workload "path: /api/v2"
;;

let test_ingress_default_path () =
  (* Default path is "/" *)
  let spec = { svc_spec with ingress_path = None } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "default path" workload "path: /"
;;

let test_extra_labels_appear_in_pod_template () =
  (* extra_labels must appear in the pod template metadata.labels block *)
  let spec = { svc_spec with extra_labels = [ "team", "platform"; "tier", "backend" ] } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "extra label team" workload {|team: "platform"|};
  assert_contains "extra label tier" workload {|tier: "backend"|}
;;

let test_extra_labels_empty_by_default () =
  (* No extra labels → no spurious keys in pod template *)
  let spec = { svc_spec with extra_labels = [] } in
  let _ns, workload = render_spec_ok spec in
  assert_absent "no team label" workload {|team:|}
;;

let test_toml_invalid_rollout_strategy () =
  (* load should raise Failure for unknown rollout_strategy values *)
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.deploy]\nrollout_strategy = \"Blue/Green\"\n";
  close_out oc;
  let raised =
    try
      let _ = Sol_cli_toml.load path in
      false
    with
    | Failure _ -> true
  in
  Sys.remove path;
  check_bool "invalid rollout_strategy raises" true raised
;;

let test_toml_reserved_label_key () =
  (* extra_labels keys starting with "sol.dev/" must be rejected *)
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.labels]
extra_labels = { "sol.dev/owner" = "platform" }
|};
  close_out oc;
  let raised =
    try
      let _ = Sol_cli_toml.load path in
      false
    with
    | Failure _ -> true
  in
  Sys.remove path;
  check_bool "reserved label key raises" true raised
;;

let test_toml_valid_rollout_recreate () =
  (* Parsing Recreate from sol.toml should populate rollout_strategy correctly *)
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.deploy]\nrollout_strategy = \"Recreate\"\n";
  close_out oc;
  let toml = Sol_cli_toml.load path in
  Sys.remove path;
  check_bool
    "rollout_strategy is Recreate"
    true
    (toml.Sol_cli_toml.rollout_strategy = Some Sol_cli_toml.Recreate)
;;

let test_toml_valid_ingress_overrides () =
  (* Parsing ingress_host and ingress_path from sol.toml *)
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.deploy]
ingress_host = "api.example.com"
ingress_path = "/v1"
|};
  close_out oc;
  let toml = Sol_cli_toml.load path in
  Sys.remove path;
  check_bool
    "ingress_host parsed"
    true
    (Option.map Sol_cli_toml.hostname_to_string toml.Sol_cli_toml.ingress_host
     = Some "api.example.com");
  check_bool
    "ingress_path parsed"
    true
    (Option.map Sol_cli_toml.ingress_path_to_string toml.Sol_cli_toml.ingress_path
     = Some "/v1")
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
  let toml = Sol_cli_toml.load path in
  Sys.remove path;
  check_bool
    "secret keys parsed"
    true
    (toml.Sol_cli_toml.secret_keys = [ "DATABASE_URL"; "API_TOKEN" ])
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
  let toml = Sol_cli_toml.load path in
  Sys.remove path;
  match toml.Sol_cli_toml.progressive_delivery with
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
  let toml = Sol_cli_toml.load path in
  Sys.remove path;
  check_bool
    "blue-green parsed"
    true
    (toml.Sol_cli_toml.progressive_delivery = Some Sol_cli_toml.Blue_green)
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
  let raised =
    try
      let _ = Sol_cli_toml.load path in
      false
    with
    | Failure _ -> true
  in
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
  let raised =
    try
      let _ = Sol_cli_toml.load path in
      false
    with
    | Failure _ -> true
  in
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
  let raised =
    try
      let _ = Sol_cli_toml.load path in
      false
    with
    | Failure _ -> true
  in
  Sys.remove path;
  check_bool "invalid canary weight raises" true raised
;;

(* ── otoml-backed parser: standard TOML shapes the old parser couldn't handle *)

let test_toml_rejects_malformed () =
  (* otoml raises on malformed TOML; old parser silently returned empty *)
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "replicas = \n";
  (* missing value *)
  close_out oc;
  let raised =
    try
      let _ = Sol_cli_toml.load path in
      false
    with
    | Failure _ -> true
  in
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
  (* Standard TOML multi-line array — old line-oriented parser couldn't handle this *)
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
  let toml = Sol_cli_toml.load path in
  Sys.remove path;
  check_bool
    "multi-line secrets array parsed"
    true
    (toml.Sol_cli_toml.secret_keys = [ "DATABASE_URL"; "API_TOKEN" ])
;;

let test_toml_dotted_section_headers () =
  (* TOML allows [infra.scale] as a dotted key table header — verify otoml handles it *)
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
  let toml = Sol_cli_toml.load path in
  Sys.remove path;
  check_bool "replicas from dotted header" true (toml.Sol_cli_toml.replicas = Some 3);
  check_bool
    "cpu from dotted header"
    true
    (Option.map Sol_cli_toml.cpu_quantity_to_string toml.Sol_cli_toml.cpu = Some "250m");
  check_bool
    "memory from dotted header"
    true
    (Option.map Sol_cli_toml.memory_quantity_to_string toml.Sol_cli_toml.memory
     = Some "256Mi")
;;

let test_toml_canary_pause_steps () =
  (* Canary steps with pause = {} and pause = {duration = 60} inline tables *)
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.rollout]
strategy = "canary"
steps = [{weight = 20}, {pause = {}}, {weight = 60}, {pause = {duration = 60}}]
|};
  close_out oc;
  let toml = Sol_cli_toml.load path in
  Sys.remove path;
  match toml.Sol_cli_toml.progressive_delivery with
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

(* ── ExternalSecret backend tests ────────────────────────────────────────── *)

(* Helper: build an ESO backend value *)
let eso_backend =
  Sol_cli_manifest.External_secrets
    { store_ref = "aws-secrets-manager"
    ; store_kind = "ClusterSecretStore"
    ; key_prefix = "myapp/"
    ; refresh_interval = "1h"
    }
;;

(* external_secret_doc should emit ExternalSecret kind and remoteRef fields,
   and must NOT contain stringData. *)
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
  in
  assert_contains "kind ExternalSecret" doc "kind: ExternalSecret";
  assert_contains "remoteRef present" doc "remoteRef:";
  assert_contains "ESO apiVersion" doc "apiVersion: external-secrets.io/v1beta1";
  assert_absent "no stringData" doc "stringData"
;;

(* All provided secret keys must appear as secretKey entries *)
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
  in
  assert_contains "POSTGRES_URL secretKey" doc "secretKey: POSTGRES_URL";
  assert_contains "STRIPE_KEY secretKey" doc "secretKey: STRIPE_KEY";
  assert_contains "SENDGRID_API_KEY secretKey" doc "secretKey: SENDGRID_API_KEY"
;;

(* The target.name must be "<name>-secrets" *)
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
  in
  assert_contains "target name is charge-svc-secrets" doc "name: charge-svc-secrets"
;;

(* render_spec with External_secrets backend must emit ExternalSecret, not Secret *)
let test_render_spec_eso_backend_no_k8s_secret () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload = render_spec_ok ~secret_backend:eso_backend spec in
  assert_contains "ExternalSecret present" workload "kind: ExternalSecret";
  assert_absent "no plain Secret kind" workload "kind: Secret"
;;

(* render_spec with ESO backend must include all keys (default + user) in data: *)
let test_render_spec_eso_backend_all_keys () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload = render_spec_ok ~secret_backend:eso_backend spec in
  assert_contains "POSTGRES_URL in ESO data" workload "secretKey: POSTGRES_URL";
  assert_contains "STRIPE_KEY in ESO data" workload "secretKey: STRIPE_KEY"
;;

(* render_spec with ESO backend must NOT contain stringData *)
let test_render_spec_eso_backend_no_stringdata () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload = render_spec_ok ~secret_backend:eso_backend spec in
  assert_absent "no stringData in ESO output" workload "stringData"
;;

(* Kubernetes_placeholder backend (default) still emits a regular Secret *)
let test_render_spec_k8s_placeholder_default () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "kind Secret present" workload "kind: Secret";
  assert_absent "no ExternalSecret" workload "kind: ExternalSecret"
;;

(* ── Config parsing policy: Kubernetes_live fails closed on missing env vars ── *)

(* When Kubernetes_live is used and a user-declared secret key is absent from
   the process environment, render_spec must return Error — not Ok with "". *)
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
       ~secret_backend:Sol_cli_manifest.Kubernetes_live
       spec_with_secret
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail ("Expected Ok when env var set, got Error: " ^ e));
  Unix.putenv "MISSING_SECRET_KEY_FOR_TEST" "";
  (* Unix.putenv cannot unset a var, so use a key that was never set. *)
  let absent_key = "__SOL_TEST_ABSENT_KEY_XQ9Z2__" in
  let spec_missing = { svc_spec with secrets = [ absent_key, "" ] } in
  match
    Sol_cli_deployment_render.render_spec
      ~workspace:"myapp"
      ~secret_backend:Sol_cli_manifest.Kubernetes_live
      spec_missing
  with
  | Error msg ->
    check_bool "error mentions the missing key" true (contains msg absent_key)
  | Ok _ -> Alcotest.fail "Expected Error when required secret env var is absent, got Ok"
;;

(* Multiple missing secret keys should all be reported in the error message. *)
let test_live_backend_multiple_missing_secrets_all_reported () =
  let absent1 = "__SOL_TEST_ABSENT_A_XQ9Z2__" in
  let absent2 = "__SOL_TEST_ABSENT_B_XQ9Z2__" in
  let spec = { svc_spec with secrets = [ absent1, ""; absent2, "" ] } in
  match
    Sol_cli_deployment_render.render_spec
      ~workspace:"myapp"
      ~secret_backend:Sol_cli_manifest.Kubernetes_live
      spec
  with
  | Error msg ->
    check_bool "error mentions first absent key" true (contains msg absent1);
    check_bool "error mentions second absent key" true (contains msg absent2)
  | Ok _ ->
    Alcotest.fail "Expected Error when required secret env vars are absent, got Ok"
;;

(* When no user-declared secrets, Kubernetes_live must still succeed even if
   the platform-default env vars (e.g. POSTGRES_URL) are absent. *)
let test_live_backend_no_user_secrets_always_succeeds () =
  let spec = { svc_spec with secrets = [] } in
  match
    Sol_cli_deployment_render.render_spec
      ~workspace:"myapp"
      ~secret_backend:Sol_cli_manifest.Kubernetes_live
      spec
  with
  | Ok (_ns, workload) -> assert_contains "kind Secret present" workload "kind: Secret"
  | Error e -> Alcotest.fail ("Expected Ok with no user secrets, got Error: " ^ e)
;;

(* ── artifact_invariants ─────────────────────────────────────────────────── *)

(* Checks the security and operational invariants every Sol-generated artifact
   must satisfy.  Call with the full workload YAML string returned by
   [render_spec_ok].  The [label] prefix appears in failure messages so you can
   tell which primitive violated the invariant.

   Invariants checked here:
   - runAsNonRoot: true            (pod-level securityContext)
   - allowPrivilegeEscalation: false  (container-level securityContext)
   - readOnlyRootFilesystem: true  (container-level securityContext)

   Invariants documented but NOT yet enforced in YAML output:
   - sol.dev/workspace label  (tracked in CODEX_STYLE_AUDIT-072)
   - sol.dev/domain label     (tracked in CODEX_STYLE_AUDIT-072) *)
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
  (* Kubernetes_placeholder must not emit real secret values in the YAML output. *)
  let spec = { svc_spec with secrets = [ "SECRET_KEY", "real-value-must-not-appear" ] } in
  let _ns, workload =
    render_spec_ok ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder spec
  in
  assert_absent
    "no real secret value in gitops output"
    workload
    "real-value-must-not-appear"
;;

(* ── workload_shape: direct deployment_doc / rollout_doc coverage ─────────── *)

let test_shape_http_service_deployment_has_ports () =
  let doc =
    Sol_cli_manifest.deployment_doc
      ~shape:Sol_cli_manifest.Http_service
      ~replicas:1
      ~cpu:"100m"
      ~memory:"128Mi"
      ~ns:"myapp-payments"
      ~name:"charge-svc"
      ~image:"sol-registry:5000/myapp/charge-svc:abc123"
      ~workspace:"myapp"
      ~domain:"payments"
      ~primitive:"svc"
      ()
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
      ~shape:Sol_cli_manifest.Background_worker
      ~replicas:1
      ~cpu:"100m"
      ~memory:"128Mi"
      ~ns:"myapp-comms"
      ~name:"notify-worker"
      ~image:"sol-registry:5000/myapp/notify-worker:abc123"
      ~workspace:"myapp"
      ~domain:"comms"
      ~primitive:"worker"
      ()
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
      ~shape:Sol_cli_manifest.Http_service
      ~replicas:1
      ~cpu:"100m"
      ~memory:"128Mi"
      ~ns:"myapp-payments"
      ~name:"charge-svc"
      ~image:"sol-registry:5000/myapp/charge-svc:abc123"
      ~pd:(Sol_cli_toml.Canary { steps = [ Sol_cli_toml.Weight 50 ] })
      ~workspace:"myapp"
      ~domain:"payments"
      ~primitive:"svc"
      ()
  in
  assert_contains "rollout Http_service containerPort" doc "containerPort: 8080";
  assert_contains "rollout Http_service readinessProbe" doc "readinessProbe:"
;;

let test_shape_rollout_background_worker_metrics_port () =
  let doc =
    Sol_cli_manifest.rollout_doc
      ~shape:Sol_cli_manifest.Background_worker
      ~replicas:1
      ~cpu:"100m"
      ~memory:"128Mi"
      ~ns:"myapp-comms"
      ~name:"notify-worker"
      ~image:"sol-registry:5000/myapp/notify-worker:abc123"
      ~pd:(Sol_cli_toml.Canary { steps = [ Sol_cli_toml.Weight 50 ] })
      ~workspace:"myapp"
      ~domain:"comms"
      ~primitive:"worker"
      ()
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

(* ── OBS-008: label taxonomy ──────────────────────────────────────────────── *)

let test_taxonomy_labels_svc () =
  let _, workload = render_spec_ok svc_spec in
  assert_contains "workspace label" workload {|workspace: "myapp"|};
  assert_contains "domain label" workload {|domain: "payments"|};
  assert_contains "service label" workload {|service: "charge-svc"|};
  assert_contains "primitive label" workload {|primitive: "svc"|};
  assert_contains "release label" workload {|release: "abc123"|}
;;

let test_taxonomy_labels_worker () =
  let _, workload = render_spec_ok worker_spec in
  assert_contains "workspace label" workload {|workspace: "myapp"|};
  assert_contains "domain label" workload {|domain: "comms"|};
  assert_contains "service label" workload {|service: "notify-worker"|};
  assert_contains "primitive label" workload {|primitive: "worker"|};
  assert_contains "release label" workload {|release: "abc123"|}
;;

let test_taxonomy_labels_fn () =
  let _, workload = render_spec_ok fn_spec in
  assert_contains "workspace label" workload {|workspace: "myapp"|};
  assert_contains "domain label" workload {|domain: "billing"|};
  assert_contains "service label" workload {|service: "invoice-fn"|};
  assert_contains "primitive label" workload {|primitive: "fn"|};
  assert_contains "release label" workload {|release: "abc123"|}
;;

(* matchLabels/selector must stay app-only -- changing selector labels would
   orphan running pods on the next rollout. The taxonomy labels only belong
   in the pod template's own labels block, rendered separately below this. *)
(* OBS-021 regression: a mixed-case/underscore workspace or domain used to
   render as-is in the manifest label while sol open's dashboard link
   normalized it differently (lowercase + hyphens only) -- the two
   permanently disagreed, so the dashboard opened empty. Both now go
   through the same Sol_cli_kubernetes_name.sanitize_label_value. *)
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

let test_release_of_image_malformed () =
  let spec = { svc_spec with image = "no-tag-image" } in
  let _, workload = render_spec_ok spec in
  assert_contains "release falls back to unknown" workload {|release: "unknown"|}
;;

let test_release_of_image_oversized_tag_truncated () =
  let long_tag = String.make 90 'a' in
  let spec = { svc_spec with image = "sol-registry:5000/myapp/charge-svc:" ^ long_tag } in
  let _, workload = render_spec_ok spec in
  (* the image: field legitimately still carries the full tag -- only the
     release label value itself must be bounded to 63 chars. *)
  assert_contains
    "release truncated to 63 chars"
    workload
    (Printf.sprintf {|release: "%s"|} (String.make 63 'a'));
  assert_absent
    "release label is not the full 90-char tag"
    workload
    (Printf.sprintf {|release: "%s"|} long_tag)
;;

let test_release_of_image_trailing_non_alnum_after_truncation () =
  (* 62 'a's + '.' lands right at the 63-char boundary with a non-alnum
     trailing character once truncated -- must be fixed up, not left as an
     invalid Kubernetes label value. *)
  let tag = String.make 62 'a' ^ "." ^ String.make 5 'b' in
  let spec = { svc_spec with image = "sol-registry:5000/myapp/charge-svc:" ^ tag } in
  let _, workload = render_spec_ok spec in
  assert_contains
    "trailing '.' replaced with a safe char"
    workload
    (Printf.sprintf {|release: "%s0"|} (String.make 62 'a'))
;;

let test_release_of_image_numeric_tag_quoted () =
  let spec = { svc_spec with image = "sol-registry:5000/myapp/charge-svc:123" } in
  let _, workload = render_spec_ok spec in
  assert_contains
    "numeric-looking release stays a quoted string"
    workload
    {|release: "123"|}
;;

(* OBS-019: sanitize_label_value applies uniformly to every taxonomy label
   value, not just release. workspace/domain/service are already bounded
   before render_spec ever reaches label rendering (namespace_result
   validates their combined length/charset upstream, and service is
   always a validated k8s_name here), so these can't be exercised through
   the full render pipeline the way release's truncation/fixup tests are
   above -- test the exposed sanitizer directly instead. *)
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

(* OBS-021: sanitize_label_value now guarantees a genuinely valid
   Kubernetes label value, not just a bounded one -- lowercases, replaces
   every invalid character (not just underscore), and strips a leading
   invalid character entirely rather than only fixing the trailing one. *)
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

(* ── discover_services filter matching ──────────────────────────────────── *)

(* Run [f] inside a fresh temp workspace root, then restore cwd and delete it. *)
let in_temp_workspace f =
  let orig_cwd = Sys.getcwd () in
  let tmpdir = Filename.temp_file "sol-manifest-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Sys.chdir tmpdir;
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir orig_cwd;
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    f
;;

(* charge_svc is the on-disk (underscored) directory name; sol new/scaffold's
   own normalize converts hyphens to underscores, so a filter typed
   hyphenated (as in FEAT-026's acceptance criteria,
   "app/payments/charge-svc") must match it too. *)
let with_charge_svc_workspace f =
  in_temp_workspace
  @@ fun () ->
  let dir = "app/payments/charge_svc" in
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote dir)));
  let oc = open_out (Filename.concat dir "Dockerfile") in
  output_string oc "FROM scratch\n";
  close_out oc;
  f ()
;;

let names services = List.map (fun (s : Sol_cli_manifest.service) -> s.name) services

let test_discover_services_hyphenated_filter_matches_underscored_dir () =
  with_charge_svc_workspace
  @@ fun () ->
  let found =
    Sol_cli_manifest.discover_services ~filter_path:(Some "app/payments/charge-svc")
  in
  Alcotest.(check (list string))
    "hyphenated full path matches"
    [ "charge_svc" ]
    (names found)
;;

let test_discover_services_hyphenated_basename_filter_matches () =
  with_charge_svc_workspace
  @@ fun () ->
  let found = Sol_cli_manifest.discover_services ~filter_path:(Some "charge-svc") in
  Alcotest.(check (list string))
    "hyphenated basename matches"
    [ "charge_svc" ]
    (names found)
;;

let test_discover_services_underscored_filter_still_matches () =
  with_charge_svc_workspace
  @@ fun () ->
  let found = Sol_cli_manifest.discover_services ~filter_path:(Some "charge_svc") in
  Alcotest.(check (list string))
    "underscored basename still matches"
    [ "charge_svc" ]
    (names found)
;;

let test_discover_services_non_matching_filter_excludes () =
  with_charge_svc_workspace
  @@ fun () ->
  let found = Sol_cli_manifest.discover_services ~filter_path:(Some "notify-worker") in
  Alcotest.(check (list string)) "non-matching filter excludes" [] (names found)
;;

let () =
  Alcotest.run
    "manifest_render"
    [ ( "svc"
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
        ; Alcotest.test_case "default schedule" `Quick test_fn_default_schedule
        ; Alcotest.test_case
            "user secret key in Secret resource"
            `Quick
            test_fn_user_secret_key_in_secret_resource
        ; Alcotest.test_case
            "pod template has app label (AUDIT-040)"
            `Quick
            test_fn_cronjob_pod_template_has_app_label
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
            "hostless ingress has no tls redirect"
            `Quick
            test_hostless_ingress_has_no_tls_redirect
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
        ; Alcotest.test_case "not in selector" `Quick test_taxonomy_labels_not_in_selector
        ; Alcotest.test_case
            "matches sol open dashboard link normalization"
            `Quick
            test_taxonomy_labels_match_dashboard_link_normalization
        ; Alcotest.test_case
            "malformed image -> unknown"
            `Quick
            test_release_of_image_malformed
        ; Alcotest.test_case
            "oversized tag truncated to 63 chars"
            `Quick
            test_release_of_image_oversized_tag_truncated
        ; Alcotest.test_case
            "trailing non-alnum after truncation fixed up"
            `Quick
            test_release_of_image_trailing_non_alnum_after_truncation
        ; Alcotest.test_case
            "numeric-looking tag stays quoted"
            `Quick
            test_release_of_image_numeric_tag_quoted
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
    ; ( "discover_services_filter"
      , [ Alcotest.test_case
            "hyphenated full path matches underscored dir"
            `Quick
            test_discover_services_hyphenated_filter_matches_underscored_dir
        ; Alcotest.test_case
            "hyphenated basename matches"
            `Quick
            test_discover_services_hyphenated_basename_filter_matches
        ; Alcotest.test_case
            "underscored filter still matches"
            `Quick
            test_discover_services_underscored_filter_still_matches
        ; Alcotest.test_case
            "non-matching filter excludes"
            `Quick
            test_discover_services_non_matching_filter_excludes
        ] )
    ]
;;
