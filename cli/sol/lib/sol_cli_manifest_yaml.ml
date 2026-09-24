(* Pure YAML generators — no Sys.command, open_out, or Sys.readdir. *)

(* ── Service model ───────────────────────────────────────────────────────── *)

type primitive =
  | Svc
  | Worker
  | Fn

type service =
  { domain : string
  ; name : string
  ; primitive : primitive
  ; dir : string
  }

let primitive_label = function
  | Svc -> "svc"
  | Worker -> "worker"
  | Fn -> "fn"
;;

type workload_shape =
  | Http_service
  | Background_worker

(* ── YAML templates ─────────────────────────────────────────────────────── *)

let default_cluster_env =
  [ (* SEC-007 / FND-0039: the transport posture is declared, not defaulted.
       In-cluster Kafka is plaintext and unauthenticated today (TLS/SASL is
       FEAT-093); rendering it explicitly makes that visible in every manifest,
       and config_of_env refuses a workload that does not state it. *)
    "KAFKA_SECURITY_PROTOCOL", "plaintext"
  ; "KAFKA_BROKERS", "redpanda.redpanda.svc.cluster.local:9093"
  ; "SCHEMA_REGISTRY_URL", "http://redpanda.redpanda.svc.cluster.local:8081"
  ; "REDPANDA_ADMIN_URL", "http://redpanda.redpanda.svc.cluster.local:9644"
  ; "LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100"
  ; ( "PUSHGATEWAY_URL"
    , "http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091" )
  ; (* OBS-042: OTLP/HTTP ingestion port, not Tempo's query port (3200) --
     Grafana's Tempo datasource reads from 3200, but a running -svc pushes
     spans to 4318 (obs-tempo-eio's TEMPO_URL). *)
    "TEMPO_URL", "http://tempo.monitoring.svc.cluster.local:4318"
  ]
;;

(* Credentials that must never appear in ConfigMap; emitted empty into a
   Secret for operators to fill in via env or a secrets manager. *)
let default_secrets = [ "POSTGRES_URL", ""; "SOL_API_KEY", "" ]
let runtime_secret_name = "sol-secrets"
let f = Printf.sprintf

let render_env_block env =
  String.concat "\n" (List.map (fun (k, v) -> f "  %s: \"%s\"" k v) env)
;;

let config_hash extra_env =
  default_cluster_env @ extra_env
  |> List.map (fun (k, v) -> k ^ "=" ^ v)
  |> String.concat "\n"
  |> Digest.string
  |> Digest.to_hex
;;

let namespace_doc ~ns =
  f
    {|---
apiVersion: v1
kind: Namespace
metadata:
  name: %s|}
    ns
;;

(* INFRA-025: binds the deploy identity's Kubernetes group to the deploy
   ClusterRole (cli/platform/infra/base/platform_deploy_rbac.tf) inside one
   namespace. Applied per application namespace by Sol_cli_substrate.ensure,
   not by Terraform -- application namespaces are created dynamically, and a
   Terraform-time ClusterRoleBinding would grant deploy these verbs in
   platform namespaces too. *)
let deploy_role_binding_doc ~ns =
  f
    {|---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: sol-deploy
  namespace: %s
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: sol-deploy
subjects:
  - kind: Group
    name: sol:deployers
    apiGroup: rbac.authorization.k8s.io|}
    ns
;;

(* DEC-038 / INFRA-057: the operator's read-only diagnostic grant, bound per
   application namespace for the same reason as deploy's -- those namespaces are
   created dynamically, and this grants observation only. *)
let operator_role_binding_doc ~ns =
  f
    {|---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: sol-operator
  namespace: %s
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: sol-operator-diagnostics
subjects:
  - kind: Group
    name: sol:operators
    apiGroup: rbac.authorization.k8s.io|}
    ns
;;

(* SEC-004: a production workload gets no ambient Kubernetes credential. Every
   Sol-rendered workload uses this ServiceAccount, so disabling token automount
   here means no pod receives a mounted service-account token. Maturity A offers
   no opt-back-in capability: a meaningful least-privilege Kubernetes-API
   permission model is deferred until a concrete workload needs one. *)
let service_account_doc ~ns ~name =
  f
    {|---
apiVersion: v1
kind: ServiceAccount
automountServiceAccountToken: false
metadata:
  name: %s
  namespace: %s|}
    name
    ns
;;

let configmap_doc ?(extra_env = []) ~ns ~name () =
  let env = default_cluster_env @ extra_env in
  f
    {|---
apiVersion: v1
kind: ConfigMap
metadata:
  name: %s-env
  namespace: %s
data:
%s|}
    name
    ns
    (render_env_block env)
;;

(* The per-workload Secret name. The convention lives here, once, because the
   shared runtime Secret is deliberately *not* workload-suffixed: it is
   [runtime_secret_name] verbatim, and the two must not be derivable from each
   other by a template that does not know which one it is rendering. *)
let workload_secret_name name = Printf.sprintf "%s-secrets" name

(* Renders the Kubernetes Secret whose identity is [name]. [name] is the *final*
   resource name -- this function applies no naming convention of its own. That is
   the whole point: a template that appends a suffix to whatever it is handed
   produced `sol-secrets-secrets` for the shared runtime Secret while every
   consumer referenced `sol-secrets`, and the only way to see it was to read the
   rendered YAML. Callers pass either [runtime_secret_name] or
   [workload_secret_name workload].

   stringData lets operators fill in real values without base64-encoding them.
   With ~redact:true (GitOps mode) all values are stripped to "" so nothing
   sensitive lands in committed manifests. *)
let secret_doc
      ?(base_secrets = default_secrets)
      ?(extra_secrets = [])
      ?(redact = false)
      ~ns
      ~name
      ()
  =
  let secrets = base_secrets @ extra_secrets in
  let secrets = if redact then List.map (fun (k, _) -> k, "") secrets else secrets in
  let comment =
    if redact
    then
      "# Populate these values before applying.\n\
       # Use `sol secret set <KEY> --env <env>` or your secrets manager.\n"
    else ""
  in
  f
    {|---
apiVersion: v1
kind: Secret
metadata:
  name: %s
  namespace: %s
type: Opaque
%sstringData:
%s|}
    name
    ns
    comment
    (render_env_block secrets)
;;

(* ExternalSecret (ESO v1beta1); the controller materialises it into a
   "<name>-secrets" Secret. secret_keys must be the full key list. *)
let external_secret_doc
      ~store_ref
      ~store_kind
      ~key_prefix
      ~refresh_interval
      ~secret_keys
      ~ns
      ~name
  =
  let remote_refs =
    String.concat
      "\n"
      (List.map
         (fun key ->
            f
              {|  - secretKey: %s
    remoteRef:
      key: %s%s|}
              key
              key_prefix
              key)
         secret_keys)
  in
  f
    {|---
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
%s|}
    name
    ns
    refresh_interval
    store_ref
    store_kind
    name
    remote_refs
;;

let render_secret_key_refs ~name secret_keys =
  match secret_keys with
  | [] -> ""
  | keys ->
    "\n        env:\n"
    ^ String.concat
        "\n"
        (List.map
           (fun key ->
              f
                {|        - name: %s
          valueFrom:
            secretKeyRef:
              name: %s-secrets
              key: %s|}
                key
                name
                key)
           keys)
;;

let render_extra_labels labels =
  (* Renders extra_labels as additional pod-template label lines (4-space indent). *)
  String.concat "\n" (List.map (fun (k, v) -> f "        %s: \"%s\"" k v) labels)
;;

(* docs/architecture/observability-design.md's identity taxonomy: workspace,
   domain, service, primitive, release, plus a sixth, `env`, sourced from
   the active deployment target -- passed to render_taxonomy_labels below
   as ?env, omitted (not a fake default) when no target resolved one, e.g.
   sol up (FEAT-026; see OBS-016 for the original gap). `release` is the
   content-addressed release id (FEAT-069) and is written verbatim: it is
   label-safe by construction (Sol_cli_release_id.t), and sanitizing it at
   the render site would let the label drift from the id the release record
   stores -- the BUG-025 failure mode in a new place. The image tag is no
   longer a label at all: it is already container.image, and re-emitting it
   here would import unbounded cardinality into Loki's label space.
   workspace/domain/service/primitive/env are still sanitized, because none
   of them is label-safe by construction at this render site.
   Rendered at pod-template indent (8 spaces), same as extra_labels. *)

(* OBS-021: delegates to Sol_cli_kubernetes_name's canonical sanitizer so
   this and Sol_cli_open.dashboard_url always agree on the same
   workspace/domain value -- keeping a separate, weaker implementation
   here (bound + trailing-char fix only, no lowercasing) is exactly how a
   rendered label and a dashboard link's query param end up permanently
   disagreeing. *)
let sanitize_label_value = Sol_cli_kubernetes_name.sanitize_label_value

let render_taxonomy_labels
      ?(indent = "        ")
      ?env
      ~workspace
      ~domain
      ~service
      ~primitive
      ~release_id
      ()
  =
  (* Every value except `release` goes through sanitize_label_value:
     workspace/domain are only indirectly bounded today (namespace_result
     validates their combined length before render is ever called) and
     service is only safe because it's always a validated k8s_name in this
     render path; neither is a guarantee at this render site itself, so
     don't rely on a value being safe by construction from somewhere else.
     `release` is the exception precisely because it *is* safe by
     construction, and must stay byte-identical to the stored id. *)
  let sanitized =
    [ "workspace", workspace
    ; "domain", domain
    ; "service", service
    ; "primitive", primitive
    ]
    |> List.map (fun (k, v) -> k, sanitize_label_value v)
  in
  let labels =
    sanitized
    @ [ "release", Sol_cli_release_id.to_string release_id ]
    @
    match env with
    | None -> []
    | Some e -> [ "env", sanitize_label_value e ]
  in
  String.concat "\n" (List.map (fun (k, v) -> f "%s%s: \"%s\"" indent k v) labels)
;;

(* CODE_LAYER-016: render per-workload volumes as a PVC per declared volume plus
   container [volumeMounts] and pod [volumes] entries. StorageClass, snapshots,
   and backup policy stay out of scope. *)
let volume_claim_name ~name ~volume_name = Printf.sprintf "%s-%s" name volume_name

let render_volume_mounts volumes =
  if volumes = []
  then ""
  else
    "        volumeMounts:\n"
    ^ String.concat
        ""
        (List.map
           (fun (v : Sol_cli_toml.volume) ->
              f "        - name: %s\n          mountPath: %s\n" v.name v.mount_path)
           volumes)
;;

let render_pod_volumes ~name volumes =
  if volumes = []
  then ""
  else
    "      volumes:\n"
    ^ String.concat
        ""
        (List.map
           (fun (v : Sol_cli_toml.volume) ->
              f
                "      - name: %s\n\
                \        persistentVolumeClaim:\n\
                \          claimName: %s\n"
                v.name
                (volume_claim_name ~name ~volume_name:v.name))
           volumes)
;;

let pvc_docs ~ns ~name volumes =
  String.concat
    "\n"
    (List.map
       (fun (v : Sol_cli_toml.volume) ->
          f
            {|---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: %s
  namespace: %s
spec:
  accessModes:
  - %s
  resources:
    requests:
      storage: %s
|}
            (volume_claim_name ~name ~volume_name:v.name)
            ns
            (Sol_cli_toml.volume_access_mode_to_string v.access_mode)
            v.size)
       volumes)
;;

(* AUDIT-080: the framework drain timeout is 30s (sol-svc/sol-worker), and
   Kubernetes' own default grace is 30s -- the two race. Sol renders a grace
   that is strictly larger than the drain bound so SIGTERM always has room to
   finish, independent of the primitive. *)
let default_termination_grace_seconds = 45

let deployment_doc
      ?(rollout_strategy = Sol_cli_toml.RollingUpdate)
      ?(extra_labels = [])
      ?(secret_keys = [])
      ?(volumes = [])
      ?env
      ?(config_hash = "")
      ?(availability = Sol_cli_availability.Single)
      ?(consumes_kafka = false)
      ?(readiness_path = "/readyz")
      ~shape
      ~replicas
      ~cpu
      ~memory
      ~ns
      ~name
      ~image
      ~workspace
      ~domain
      ~primitive
      ~release_id
      ()
  =
  let ports_section =
    match shape with
    | Http_service ->
      {|        ports:
        - containerPort: 8080
|}
    | Background_worker ->
      {|        ports:
        - containerPort: 9090
|}
  in
  (* AUDIT-080: the probes a workload can honestly claim. An HTTP service is
     healthy when it answers; a Kafka consumer is *ready* when its partitions
     are assigned and *live* while it keeps polling, which is a different
     statement from "the process is up" -- a hung consumer must be replaced. A
     worker that consumes nothing has no observable consumer state, so Sol
     renders no liveness/readiness claim rather than a default that asserts
     nothing. *)
  let probe_section =
    match shape, consumes_kafka with
    | Http_service, _ ->
      (* INFRA-073: readiness is /readyz, which sol-svc turns 503 as shutdown
         begins; liveness and startup stay on /healthz. A TypeScript service
         renders /healthz until its framework serves /readyz (FEAT-096). *)
      f
        {|        startupProbe:
          httpGet:
            path: /healthz
            port: 8080
          failureThreshold: 30
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: %s
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
|}
        readiness_path
    | Background_worker, true ->
      {|        startupProbe:
          httpGet:
            path: /readyz
            port: 9090
          failureThreshold: 60
          periodSeconds: 5
        readinessProbe:
          httpGet:
            path: /readyz
            port: 9090
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /livez
            port: 9090
          periodSeconds: 10
          failureThreshold: 3
|}
    | Background_worker, false -> ""
  in
  let strategy_type =
    match rollout_strategy with
    | Sol_cli_toml.Recreate -> "Recreate"
    | Sol_cli_toml.RollingUpdate -> "RollingUpdate"
  in
  let extra_labels_section =
    if extra_labels = [] then "" else "\n" ^ render_extra_labels extra_labels
  in
  let secret_env_section = render_secret_key_refs ~name secret_keys in
  let volume_mounts_section = render_volume_mounts volumes in
  let pod_volumes_section = render_pod_volumes ~name volumes in
  (* AUDIT-080: spread a node-failure-tolerant workload across nodes, so losing
     one node cannot take every replica with it. The pod anti-affinity is
     expressed as a hard spread: the claim is a guarantee, not a preference. *)
  let availability_section =
    if Sol_cli_availability.is_node_failure_tolerant availability
    then
      f
        {|      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: %s
|}
        name
    else ""
  in
  let grace_section =
    f "      terminationGracePeriodSeconds: %d\n" default_termination_grace_seconds
  in
  let pod_spec_extras = grace_section ^ availability_section ^ pod_volumes_section in
  let taxonomy_labels_section =
    render_taxonomy_labels ?env ~workspace ~domain ~service:name ~primitive ~release_id ()
  in
  let prometheus_annotations =
    match shape with
    | Http_service ->
      "        prometheus.io/scrape: \"true\"\n        prometheus.io/port: \"8080\"\n"
    | Background_worker ->
      "        prometheus.io/scrape: \"true\"\n        prometheus.io/port: \"9090\"\n"
  in
  f
    {|---
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
%s      containers:
      - name: %s
        image: %s
        imagePullPolicy: Always
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
%s%s%s        envFrom:
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
%s|}
    name
    ns
    replicas
    strategy_type
    name
    name
    taxonomy_labels_section
    extra_labels_section
    config_hash
    prometheus_annotations
    name
    pod_spec_extras
    name
    image
    ports_section
    volume_mounts_section
    secret_env_section
    name
    name
    cpu
    memory
    cpu
    memory
    probe_section
;;

(* AUDIT-080: a node-failure-tolerant workload gets a voluntary-disruption
   budget so a drain cannot evict every ready replica at once. Rendered only for
   that claim -- a [single] workload has no tolerance to protect. *)
let pdb_doc ~ns ~name ~replicas =
  f
    {|---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: %s
  namespace: %s
spec:
  minAvailable: %d
  selector:
    matchLabels:
      app: %s
|}
    name
    ns
    (max 1 (replicas - 1))
    name
;;

(* ── Argo Rollouts helpers ────────────────────────────────────────────────── *)

(* Render a single canary step as a YAML list item with 10-space indent. *)
let render_canary_step = function
  | Sol_cli_toml.Weight n -> f "          - setWeight: %d" n
  | Sol_cli_toml.Pause None -> "          - pause: {}"
  | Sol_cli_toml.Pause (Some d) -> f "          - pause: {duration: %d}" d
;;

(* Render the Argo Rollout strategy block for canary. *)
let render_canary_strategy steps =
  let step_lines = String.concat "\n" (List.map render_canary_step steps) in
  f
    {|      canary:
        steps:
%s|}
    step_lines
;;

(* Render the Argo Rollout strategy block for blue-green. *)
let render_blue_green_strategy name =
  f
    {|      blueGreen:
        activeService: %s-active
        previewService: %s-preview
        autoPromotionEnabled: false|}
    name
    name
;;

(** [rollout_doc] renders an Argo Rollout resource instead of a Deployment. The
    pod template is the same as a Deployment; only the top-level kind,
    apiVersion, and strategy section differ. [progressive_delivery] must be
    [Some _] — callers in [render_spec] only invoke this when it is set. *)
let rollout_doc
      ?(extra_labels = [])
      ?(secret_keys = [])
      ?(volumes = [])
      ?(config_hash = "")
      ?env
      ?(availability = Sol_cli_availability.Single)
      ?(consumes_kafka = false)
      ?(readiness_path = "/readyz")
      ~shape
      ~replicas
      ~cpu
      ~memory
      ~ns
      ~name
      ~image
      ~pd
      ~workspace
      ~domain
      ~primitive
      ~release_id
      ()
  =
  let ports_section =
    match shape with
    | Http_service ->
      {|        ports:
        - containerPort: 8080
|}
    | Background_worker ->
      {|        ports:
        - containerPort: 9090
|}
  in
  (* AUDIT-080: identical probe policy to [deployment_doc] -- a progressive
     rollout must not weaken the availability claim the app declared. *)
  let probe_section =
    match shape, consumes_kafka with
    | Http_service, _ ->
      (* INFRA-073: readiness is /readyz, which sol-svc turns 503 as shutdown
         begins; liveness and startup stay on /healthz. A TypeScript service
         renders /healthz until its framework serves /readyz (FEAT-096). *)
      f
        {|        startupProbe:
          httpGet:
            path: /healthz
            port: 8080
          failureThreshold: 30
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: %s
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
|}
        readiness_path
    | Background_worker, true ->
      {|        startupProbe:
          httpGet:
            path: /readyz
            port: 9090
          failureThreshold: 60
          periodSeconds: 5
        readinessProbe:
          httpGet:
            path: /readyz
            port: 9090
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /livez
            port: 9090
          periodSeconds: 10
          failureThreshold: 3
|}
    | Background_worker, false -> ""
  in
  let extra_labels_section =
    if extra_labels = [] then "" else "\n" ^ render_extra_labels extra_labels
  in
  let secret_env_section = render_secret_key_refs ~name secret_keys in
  let volume_mounts_section = render_volume_mounts volumes in
  let pod_volumes_section = render_pod_volumes ~name volumes in
  let availability_section =
    if Sol_cli_availability.is_node_failure_tolerant availability
    then
      f
        {|      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: %s
|}
        name
    else ""
  in
  let grace_section =
    f "      terminationGracePeriodSeconds: %d\n" default_termination_grace_seconds
  in
  let pod_spec_extras = grace_section ^ availability_section ^ pod_volumes_section in
  let taxonomy_labels_section =
    render_taxonomy_labels ?env ~workspace ~domain ~service:name ~primitive ~release_id ()
  in
  let prometheus_annotations =
    match shape with
    | Http_service ->
      "        prometheus.io/scrape: \"true\"\n        prometheus.io/port: \"8080\"\n"
    | Background_worker ->
      "        prometheus.io/scrape: \"true\"\n        prometheus.io/port: \"9090\"\n"
  in
  let strategy_block =
    match pd with
    | Sol_cli_toml.Canary { steps } -> render_canary_strategy steps
    | Sol_cli_toml.Blue_green -> render_blue_green_strategy name
  in
  f
    {|---
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
%s      containers:
      - name: %s
        image: %s
        imagePullPolicy: Always
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
%s%s%s        envFrom:
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
%s|}
    name
    ns
    replicas
    name
    name
    taxonomy_labels_section
    extra_labels_section
    config_hash
    prometheus_annotations
    name
    pod_spec_extras
    name
    image
    ports_section
    volume_mounts_section
    secret_env_section
    name
    name
    cpu
    memory
    cpu
    memory
    probe_section
    strategy_block
;;

(** Two ClusterIP Services required by the blue-green strategy: [<name>-active]
    receives live traffic; [<name>-preview] receives canary traffic. Both select
    pods with the [app: <name>] label — Argo manages the selector patch. *)
let blue_green_service_docs ~ns ~name =
  let make_svc svc_name =
    f
      {|---
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
    targetPort: 8080|}
      svc_name
      ns
      name
  in
  make_svc (name ^ "-active") ^ "\n" ^ make_svc (name ^ "-preview")
;;

(* ── Standard Service ────────────────────────────────────────────────────── *)

let service_doc ~ns ~name =
  f
    {|---
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
    targetPort: 8080|}
    name
    ns
    name
;;

let ingress_doc
      ?(ingress_host = "")
      ?(ingress_path = "/")
      ?(cluster_issuer = "letsencrypt-prod")
      ?tls_secret_name
      ~ns
      ~name
      ()
  =
  let rule_head =
    (* BUG-021: never emit a hostless rule. nginx matches on host+path and its
       admission webhook rejects a duplicate host+path cluster-wide, so two
       services without an ingress_host (or two workspaces sharing `sol-local`)
       collided on host "" + path "/" and broke `sol up`. Give each a
       per-service dev host instead; including the namespace keeps it unique
       when several workspaces share a cluster. It is HTTP-only -- the TLS,
       cert-manager, and ssl-redirect bits below stay off unless a real
       `ingress_host` was declared. *)
    if ingress_host = ""
    then f "  - host: %s.%s.localhost\n    http:" name ns
    else f "  - host: %s\n    http:" ingress_host
  in
  let annotations =
    if ingress_host = ""
    then ""
    else
      f
        {|
  annotations:
    cert-manager.io/cluster-issuer: %s
    nginx.ingress.kubernetes.io/ssl-redirect: "true"|}
        cluster_issuer
  in
  let tls =
    if ingress_host = ""
    then ""
    else (
      let secret_name = Option.value tls_secret_name ~default:(name ^ "-tls") in
      f
        {|
  tls:
  - hosts:
    - %s
    secretName: %s|}
        ingress_host
        secret_name)
  in
  f
    {|---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: %s
  namespace: %s
%s
spec:
  ingressClassName: nginx%s
  rules:
%s
      paths:
      - path: %s
        pathType: Prefix
        backend:
          service:
            name: %s
            port:
              number: 80|}
    name
    ns
    annotations
    tls
    rule_head
    ingress_path
    name
;;

let network_policy_doc ?(egress_to = []) ?(ingress_from = []) ~ns ~name () =
  let ingress_from =
    ingress_from
    |> List.map (fun (from_ns, from_name) ->
      f
        {|  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: %s
      podSelector:
        matchLabels:
          app: %s
    ports:
    - port: 8080|}
        from_ns
        from_name)
    |> String.concat "\n"
  in
  let egress_to =
    (* No `ports:` here, deliberately. Egress policy is evaluated on the packet
       leaving the caller, before kube-proxy DNATs the Service ClusterIP -- so a
       port restriction would have to name the target's *Service* port (80),
       not its container port (8080). A CNI that instead matches post-DNAT
       would need 8080, so no single number is portable. Scoping by the target
       pod (namespace + app) with no port restriction is what the platform
       dependency rules above already do, and it works under either
       interpretation. The ingress side below keeps 8080 because ingress is
       always evaluated after DNAT, against the target pod's real port. *)
    egress_to
    |> List.map (fun (to_ns, to_name) ->
      f
        {|  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: %s
      podSelector:
        matchLabels:
          app: %s|}
        to_ns
        to_name)
    |> String.concat "\n"
  in
  let opt_section s = if s = "" then "" else "\n" ^ s in
  f
    {|---
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
%s
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
          kubernetes.io/metadata.name: monitoring
%s|}
    name
    ns
    name
    (opt_section ingress_from)
    (opt_section egress_to)
;;

let cronjob_doc
      ?(secret_keys = [])
      ?env
      ~ns
      ~name
      ~image
      ~schedule
      ~concurrency_policy
      ~backoff_limit
      ~cpu
      ~memory
      ~workspace
      ~domain
      ~release_id
      ()
  =
  let secret_env_section = render_secret_key_refs ~name secret_keys in
  let taxonomy_labels_section =
    render_taxonomy_labels
      ~indent:"            "
      ?env
      ~workspace
      ~domain
      ~service:name
      ~primitive:"fn"
      ~release_id
      ()
  in
  f
    {|---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: %s
  namespace: %s
spec:
  schedule: "%s"
  concurrencyPolicy: %s
  jobTemplate:
    spec:
      backoffLimit: %d
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
                cpu: %s
                memory: %s
              limits:
                cpu: %s
                memory: %s|}
    name
    ns
    schedule
    concurrency_policy
    backoff_limit
    name
    taxonomy_labels_section
    name
    name
    image
    secret_env_section
    name
    name
    cpu
    memory
    cpu
    memory
;;
