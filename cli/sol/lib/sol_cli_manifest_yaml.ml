(* Pure YAML generators — no Sys.command, open_out, or Sys.readdir. *)

(* ── Service model ───────────────────────────────────────────────────────── *)

type primitive = Svc | Worker | Fn

type service = {
  domain : string;
  name   : string;
  primitive : primitive;
  dir    : string;
}

let primitive_label = function Svc -> "svc" | Worker -> "worker" | Fn -> "fn"

type workload_shape = Http_service | Background_worker

(* ── Schedule extraction for -fn ─────────────────────────────────────────── *)

let extract_schedule ~dir ~name:_ =
  (* Read from sol.toml's [service] section, not by scanning OCaml source
     (which false-positived on stray "schedule = " literals). Defaults hourly. *)
  let toml_path = Filename.concat dir "sol.toml" in
  match Sol_cli_toml.load_result toml_path with
  | Ok { Sol_cli_toml.schedule = Some s; _ } -> s
  | Ok _  -> "0 * * * *"
  | Error _ -> "0 * * * *"

(* ── YAML templates ─────────────────────────────────────────────────────── *)

let default_cluster_env = [
  "KAFKA_BROKERS",       "redpanda.redpanda.svc.cluster.local:9093";
  "SCHEMA_REGISTRY_URL", "http://redpanda.redpanda.svc.cluster.local:8081";
  "REDPANDA_ADMIN_URL",  "http://redpanda.redpanda.svc.cluster.local:9644";
  "LOKI_URL",            "http://loki.monitoring.svc.cluster.local:3100";
  "PUSHGATEWAY_URL",     "http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091";
  (* OBS-042: OTLP/HTTP ingestion port, not Tempo's query port (3200) --
     Grafana's Tempo datasource reads from 3200, but a running -svc pushes
     spans to 4318 (obs-tempo-eio's TEMPO_URL). *)
  "TEMPO_URL",           "http://tempo.monitoring.svc.cluster.local:4318";
]

(* Credentials that must never appear in ConfigMap; emitted empty into a
   Secret for operators to fill in via env or a secrets manager. *)
let default_secrets = [
  "POSTGRES_URL", "";
]

let runtime_secret_name = "sol-secrets"

let f = Printf.sprintf

let render_env_block env =
  String.concat "\n" (List.map (fun (k, v) -> f "  %s: \"%s\"" k v) env)

let config_hash extra_env =
  default_cluster_env @ extra_env
  |> List.map (fun (k, v) -> k ^ "=" ^ v)
  |> String.concat "\n"
  |> Digest.string
  |> Digest.to_hex

let namespace_doc ~ns =
  f {|---
apiVersion: v1
kind: Namespace
metadata:
  name: %s|} ns

let service_account_doc ~ns ~name =
  f {|---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: %s
  namespace: %s|} name ns

let configmap_doc ?(extra_env = []) ~ns ~name () =
  let env = default_cluster_env @ extra_env in
  f {|---
apiVersion: v1
kind: ConfigMap
metadata:
  name: %s-env
  namespace: %s
data:
%s|} name ns (render_env_block env)

(* stringData lets operators fill in real values without base64-encoding them.
   With ~redact:true (GitOps mode) all values are stripped to "" so nothing
   sensitive lands in committed manifests. *)
let secret_doc ?(base_secrets = default_secrets) ?(extra_secrets = []) ?(redact = false) ~ns ~name () =
  let secrets = base_secrets @ extra_secrets in
  let secrets = if redact then List.map (fun (k, _) -> (k, "")) secrets else secrets in
  let comment = if redact then
    "# Populate these values before applying.\n\
     # Use `sol secret set <KEY> --env <env>` or your secrets manager.\n"
  else "" in
  f {|---
apiVersion: v1
kind: Secret
metadata:
  name: %s-secrets
  namespace: %s
type: Opaque
%sstringData:
%s|} name ns comment (render_env_block secrets)

(* ExternalSecret (ESO v1beta1); the controller materialises it into a
   "<name>-secrets" Secret. secret_keys must be the full key list. *)
let external_secret_doc ~store_ref ~store_kind ~key_prefix ~refresh_interval ~secret_keys ~ns ~name =
  let remote_refs =
    String.concat "\n" (List.map (fun key ->
      f {|  - secretKey: %s
    remoteRef:
      key: %s%s|} key key_prefix key
    ) secret_keys)
  in
  f {|---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: %s-secrets
  namespace: %s
spec:
  refreshInterval: %s
  secretStoreRef:
    name: %s
    kind: %s
  target:
    name: %s-secrets
    creationPolicy: Owner
  data:
%s|} name ns refresh_interval store_ref store_kind name remote_refs

let render_secret_key_refs ~name secret_keys =
  match secret_keys with
  | [] -> ""
  | keys ->
    "\n        env:\n" ^
    String.concat "\n" (List.map (fun key ->
      f {|        - name: %s
          valueFrom:
            secretKeyRef:
              name: %s-secrets
              key: %s|} key name key
    ) keys)

let render_extra_labels labels =
  (* Renders extra_labels as additional pod-template label lines (4-space indent). *)
  String.concat "\n" (List.map (fun (k, v) -> f "        %s: \"%s\"" k v) labels)

(* docs/architecture/observability-design.md's identity taxonomy: workspace,
   domain, service, primitive, release, plus a sixth, `env`, sourced from
   the active deployment target -- passed to render_taxonomy_labels below
   as ?env, omitted (not a fake default) when no target resolved one, e.g.
   sol up (FEAT-026; see OBS-016 for the original gap). `release` is the
   image tag, the part after the last ':'
   -- falls back to "unknown" for a tag-less/malformed image ref rather
   than raising, since a bad label value is far cheaper than a failed
   deploy; sanitize_label_value bounds it to Kubernetes' 63-char
   label-value limit for the same reason (an oversized value from a long
   CI-generated tag would otherwise make `kubectl apply` fail outright).
   Rendered at pod-template indent (8 spaces), same as extra_labels. *)
let release_of_image image =
  match String.rindex_opt image ':' with
  | Some i -> String.sub image (i + 1) (String.length image - i - 1)
  | None -> "unknown"

(* OBS-021: delegates to Sol_cli_kubernetes_name's canonical sanitizer so
   this and Sol_cli_open.dashboard_url always agree on the same
   workspace/domain value -- keeping a separate, weaker implementation
   here (bound + trailing-char fix only, no lowercasing) is exactly how a
   rendered label and a dashboard link's query param end up permanently
   disagreeing. *)
let sanitize_label_value = Sol_cli_kubernetes_name.sanitize_label_value

let render_taxonomy_labels ?(indent = "        ") ?env ~workspace ~domain ~service ~primitive ~image () =
  (* Every value goes through sanitize_label_value uniformly -- workspace/
     domain are only indirectly bounded today (namespace_result validates
     their combined length before render is ever called) and service is
     only safe because it's always a validated k8s_name in this render
     path; neither is a guarantee at this render site itself, so don't
     rely on a value being safe by construction from somewhere else. *)
  [ "workspace", workspace
  ; "domain", domain
  ; "service", service
  ; "primitive", primitive
  ; "release", release_of_image image
  ]
  @ (match env with None -> [] | Some e -> [ "env", e ])
  |> List.map (fun (k, v) -> f "%s%s: \"%s\"" indent k (sanitize_label_value v))
  |> String.concat "\n"

let deployment_doc ?(rollout_strategy = Sol_cli_toml.RollingUpdate)
                   ?(extra_labels = [])
                   ?(secret_keys = [])
                   ?env
                   ?(config_hash = "")
                   ~shape ~replicas ~cpu ~memory ~ns ~name ~image
                   ~workspace ~domain ~primitive () =
  let ports_section =
    match shape with
    | Http_service -> {|        ports:
        - containerPort: 8080
|}
    | Background_worker -> {|        ports:
        - containerPort: 9090
|}
  in
  let probe_section =
    if shape = Http_service then {|        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
|} else ""
  in
  let strategy_type = match rollout_strategy with
    | Sol_cli_toml.Recreate      -> "Recreate"
    | Sol_cli_toml.RollingUpdate -> "RollingUpdate"
  in
  let extra_labels_section =
    if extra_labels = [] then ""
    else "\n" ^ render_extra_labels extra_labels
  in
  let secret_env_section = render_secret_key_refs ~name secret_keys in
  let taxonomy_labels_section =
    render_taxonomy_labels ?env ~workspace ~domain ~service:name ~primitive ~image ()
  in
  let prometheus_annotations = match shape with
    | Http_service ->
      "        prometheus.io/scrape: \"true\"\n        prometheus.io/port: \"8080\"\n"
    | Background_worker ->
      "        prometheus.io/scrape: \"true\"\n        prometheus.io/port: \"9090\"\n"
  in
  f {|---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: %s
  namespace: %s
spec:
  replicas: %d
  strategy:
    type: %s
  selector:
    matchLabels:
      app: %s
  template:
    metadata:
      labels:
        app: %s
%s%s
      annotations:
        sol.dev/config-hash: "%s"
%s    spec:
      serviceAccountName: %s
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: %s
        image: %s
        imagePullPolicy: Always
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
%s%s        envFrom:
        - configMapRef:
            name: %s-env
        - secretRef:
            name: %s-secrets
        resources:
          requests:
            cpu: %s
            memory: %s
          limits:
            cpu: %s
            memory: %s
%s|} name ns replicas strategy_type name name taxonomy_labels_section extra_labels_section config_hash prometheus_annotations name name image ports_section secret_env_section name name cpu memory cpu memory probe_section

(* ── Argo Rollouts helpers ────────────────────────────────────────────────── *)

(* Render a single canary step as a YAML list item with 10-space indent. *)
let render_canary_step = function
  | Sol_cli_toml.Weight n ->
    f "          - setWeight: %d" n
  | Sol_cli_toml.Pause None ->
    "          - pause: {}"
  | Sol_cli_toml.Pause (Some d) ->
    f "          - pause: {duration: %d}" d

(* Render the Argo Rollout strategy block for canary. *)
let render_canary_strategy steps =
  let step_lines = String.concat "\n" (List.map render_canary_step steps) in
  f {|      canary:
        steps:
%s|} step_lines

(* Render the Argo Rollout strategy block for blue-green. *)
let render_blue_green_strategy name =
  f {|      blueGreen:
        activeService: %s-active
        previewService: %s-preview
        autoPromotionEnabled: false|} name name

(** [rollout_doc] renders an Argo Rollout resource instead of a Deployment.
    The pod template is the same as a Deployment; only the top-level kind,
    apiVersion, and strategy section differ.  [progressive_delivery] must be
    [Some _] — callers in [render_spec] only invoke this when it is set. *)
let rollout_doc ?(extra_labels = []) ?(secret_keys = []) ?(config_hash = "") ?env ~shape ~replicas ~cpu ~memory ~ns ~name ~image ~pd ~workspace ~domain ~primitive () =
  let ports_section =
    match shape with
    | Http_service -> {|        ports:
        - containerPort: 8080
|}
    | Background_worker -> {|        ports:
        - containerPort: 9090
|}
  in
  let probe_section =
    if shape = Http_service then {|        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
|} else ""
  in
  let extra_labels_section =
    if extra_labels = [] then ""
    else "\n" ^ render_extra_labels extra_labels
  in
  let secret_env_section = render_secret_key_refs ~name secret_keys in
  let taxonomy_labels_section =
    render_taxonomy_labels ?env ~workspace ~domain ~service:name ~primitive ~image ()
  in
  let prometheus_annotations = match shape with
    | Http_service ->
      "        prometheus.io/scrape: \"true\"\n        prometheus.io/port: \"8080\"\n"
    | Background_worker ->
      "        prometheus.io/scrape: \"true\"\n        prometheus.io/port: \"9090\"\n"
  in
  let strategy_block = match pd with
    | Sol_cli_toml.Canary { steps } -> render_canary_strategy steps
    | Sol_cli_toml.Blue_green       -> render_blue_green_strategy name
  in
  f {|---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: %s
  namespace: %s
spec:
  replicas: %d
  selector:
    matchLabels:
      app: %s
  template:
    metadata:
      labels:
        app: %s
%s%s
      annotations:
        sol.dev/config-hash: "%s"
%s    spec:
      serviceAccountName: %s
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: %s
        image: %s
        imagePullPolicy: Always
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
%s%s        envFrom:
        - configMapRef:
            name: %s-env
        - secretRef:
            name: %s-secrets
        resources:
          requests:
            cpu: %s
            memory: %s
          limits:
            cpu: %s
            memory: %s
%s
  strategy:
%s|} name ns replicas name name taxonomy_labels_section extra_labels_section config_hash prometheus_annotations name name image ports_section secret_env_section name name cpu memory cpu memory probe_section strategy_block

(** Two ClusterIP Services required by the blue-green strategy:
    [<name>-active] receives live traffic; [<name>-preview] receives canary traffic.
    Both select pods with the [app: <name>] label — Argo manages the selector patch. *)
let blue_green_service_docs ~ns ~name =
  let make_svc svc_name =
    f {|---
apiVersion: v1
kind: Service
metadata:
  name: %s
  namespace: %s
spec:
  type: ClusterIP
  selector:
    app: %s
  ports:
  - port: 80
    targetPort: 8080|} svc_name ns name
  in
  make_svc (name ^ "-active") ^ "\n" ^ make_svc (name ^ "-preview")

(* ── Standard Service ────────────────────────────────────────────────────── *)

let service_doc ~ns ~name =
  f {|---
apiVersion: v1
kind: Service
metadata:
  name: %s
  namespace: %s
spec:
  type: ClusterIP
  selector:
    app: %s
  ports:
  - port: 80
    targetPort: 8080|} name ns name

let ingress_doc ?(ingress_host = "") ?(ingress_path = "/") ~ns ~name () =
  (* host line is optional — omit to match all hostnames. *)
  let host_line =
    if ingress_host = "" then ""
    else f "    host: %s\n" ingress_host
  in
  f {|---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: %s
  namespace: %s
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  rules:
  - %shttp:
      paths:
      - path: %s
        pathType: Prefix
        backend:
          service:
            name: %s
            port:
              number: 80|} name ns host_line ingress_path name

let network_policy_doc ~ns ~name =
  f {|---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: %s-netpol
  namespace: %s
spec:
  podSelector:
    matchLabels:
      app: %s
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
    - podSelector: {}
  egress:
  - ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: redpanda
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: postgresql
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring|} name ns name

let cronjob_doc ?(secret_keys = []) ?env ~ns ~name ~image ~schedule ~workspace ~domain () =
  let secret_env_section = render_secret_key_refs ~name secret_keys in
  let taxonomy_labels_section =
    render_taxonomy_labels ~indent:"            " ?env ~workspace ~domain ~service:name ~primitive:"fn" ~image ()
  in
  f {|---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: %s
  namespace: %s
spec:
  schedule: "%s"
  jobTemplate:
    spec:
      backoffLimit: 3
      template:
        metadata:
          labels:
            app: %s
%s
        spec:
          serviceAccountName: %s
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            runAsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
          - name: %s
            image: %s
            imagePullPolicy: Always
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
%s
            envFrom:
            - configMapRef:
                name: %s-env
            - secretRef:
                name: %s-secrets
            resources:
              requests:
                cpu: 100m
                memory: 128Mi
              limits:
                cpu: 250m
                memory: 256Mi|} name ns schedule name taxonomy_labels_section name name image secret_env_section name name
