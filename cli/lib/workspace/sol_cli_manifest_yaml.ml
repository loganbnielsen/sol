(* Pure manifest builders -- no processes, open_out, or Sys.readdir. Every
   manifest is a [Sol_cli_yaml] value, rendered once by the caller (REFAC-131);
   no YAML is assembled from text here. *)

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

(* ── Manifests ───────────────────────────────────────────────────────────── *)

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

module Y = Sol_cli_yaml

let config_hash extra_env =
  default_cluster_env @ extra_env
  |> List.map (fun (k, v) -> k ^ "=" ^ v)
  |> String.concat "\n"
  |> Digest.string
  |> Digest.to_hex
;;

(* A mapping whose values Sol has always written quoted: env data, labels,
   annotations. *)
let quoted_map pairs = pairs |> List.map (fun (k, v) -> k, Y.quoted v) |> Y.map
let metadata ~ns ~name = Y.map [ "name", Y.string name; "namespace", Y.string ns ]
let app_selector name = Y.map [ "app", Y.string name ]

let resource ?comments ~api_version ~kind fields =
  Y.document
    ?comments
    (Y.map (("apiVersion", Y.string api_version) :: ("kind", Y.string kind) :: fields))
;;

let namespace_doc ~ns =
  resource
    ~api_version:"v1"
    ~kind:"Namespace"
    [ "metadata", Y.map [ "name", Y.string ns ] ]
;;

let role_binding_doc ~ns ~name ~cluster_role ~group =
  resource
    ~api_version:"rbac.authorization.k8s.io/v1"
    ~kind:"RoleBinding"
    [ "metadata", metadata ~ns ~name
    ; ( "roleRef"
      , Y.map
          [ "apiGroup", Y.string "rbac.authorization.k8s.io"
          ; "kind", Y.string "ClusterRole"
          ; "name", Y.string cluster_role
          ] )
    ; ( "subjects"
      , Y.list
          [ Y.map
              [ "kind", Y.string "Group"
              ; "name", Y.string group
              ; "apiGroup", Y.string "rbac.authorization.k8s.io"
              ]
          ] )
    ]
;;

(* INFRA-025: binds the deploy identity's Kubernetes group to the deploy
   ClusterRole (platform/cloud/modules/platform/platform_deploy_rbac.tf) inside one
   namespace. Applied per application namespace by Sol_cli_substrate.ensure,
   not by Terraform -- application namespaces are created dynamically, and a
   Terraform-time ClusterRoleBinding would grant deploy these verbs in
   platform namespaces too. *)
let deploy_role_binding_doc ~ns =
  role_binding_doc
    ~ns
    ~name:"sol-deploy"
    ~cluster_role:"sol-deploy"
    ~group:"sol:deployers"
;;

(* DEC-038 / INFRA-057: the operator's read-only diagnostic grant, bound per
   application namespace for the same reason as deploy's -- those namespaces are
   created dynamically, and this grants observation only. *)
let operator_role_binding_doc ~ns =
  role_binding_doc
    ~ns
    ~name:"sol-operator"
    ~cluster_role:"sol-operator-diagnostics"
    ~group:"sol:operators"
;;

(* SEC-004: a production workload gets no ambient Kubernetes credential. Every
   Sol-rendered workload uses this ServiceAccount, so disabling token automount
   here means no pod receives a mounted service-account token. Maturity A offers
   no opt-back-in capability: a meaningful least-privilege Kubernetes-API
   permission model is deferred until a concrete workload needs one. *)
let service_account_doc ~ns ~name =
  resource
    ~api_version:"v1"
    ~kind:"ServiceAccount"
    [ "automountServiceAccountToken", Y.bool false; "metadata", metadata ~ns ~name ]
;;

let configmap_doc ?(extra_env = []) ~ns ~name () =
  resource
    ~api_version:"v1"
    ~kind:"ConfigMap"
    [ "metadata", metadata ~ns ~name:(name ^ "-env")
    ; "data", quoted_map (default_cluster_env @ extra_env)
    ]
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
  let comments =
    if redact
    then
      [ "Populate these values before applying."
      ; "Use `sol secret set <KEY> --env <env>` or your secrets manager."
      ]
    else []
  in
  resource
    ~comments
    ~api_version:"v1"
    ~kind:"Secret"
    [ "metadata", metadata ~ns ~name
    ; "type", Y.string "Opaque"
    ; "stringData", quoted_map secrets
    ]
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
  let remote_ref key =
    Y.map
      [ "secretKey", Y.string key
      ; "remoteRef", Y.map [ "key", Y.string (key_prefix ^ key) ]
      ]
  in
  resource
    ~api_version:"external-secrets.io/v1beta1"
    ~kind:"ExternalSecret"
    [ "metadata", metadata ~ns ~name:(workload_secret_name name)
    ; ( "spec"
      , Y.map
          [ "refreshInterval", Y.string refresh_interval
          ; ( "secretStoreRef"
            , Y.map [ "name", Y.string store_ref; "kind", Y.string store_kind ] )
          ; ( "target"
            , Y.map
                [ "name", Y.string (workload_secret_name name)
                ; "creationPolicy", Y.string "Owner"
                ] )
          ; "data", Y.list (List.map remote_ref secret_keys)
          ] )
    ]
;;

let secret_key_refs ~name secret_keys =
  secret_keys
  |> List.map (fun key ->
    Y.map
      [ "name", Y.string key
      ; ( "valueFrom"
        , Y.map
            [ ( "secretKeyRef"
              , Y.map
                  [ "name", Y.string (workload_secret_name name); "key", Y.string key ] )
            ] )
      ])
;;

(* docs/architecture/observability-design.md's identity taxonomy: workspace,
   domain, service, primitive, release, plus a sixth, `env`, sourced from
   the active deployment target -- passed to taxonomy_labels below
   as ?env, omitted (not a fake default) when no target resolved one, e.g.
   sol up (FEAT-026; see OBS-016 for the original gap). `release` is the
   content-addressed release id (FEAT-069) and is written verbatim: it is
   label-safe by construction (Sol_cli_release_id.t), and sanitizing it at
   the render site would let the label drift from the id the release record
   stores -- the BUG-025 failure mode in a new place. The image tag is no
   longer a label at all: it is already container.image, and re-emitting it
   here would import unbounded cardinality into Loki's label space.
   workspace/domain/service/primitive/env are still sanitized, because none
   of them is label-safe by construction at this render site. *)

(* OBS-021: delegates to Sol_cli_kubernetes_name's canonical sanitizer so
   this and Sol_cli_open.dashboard_url always agree on the same
   workspace/domain value -- keeping a separate, weaker implementation
   here (bound + trailing-char fix only, no lowercasing) is exactly how a
   rendered label and a dashboard link's query param end up permanently
   disagreeing. *)
let sanitize_label_value = Sol_cli_kubernetes_name.sanitize_label_value

let taxonomy_labels ?env ~workspace ~domain ~service ~primitive ~release_id () =
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
  sanitized
  @ [ "release", Sol_cli_release_id.to_string release_id ]
  @
  match env with
  | None -> []
  | Some e -> [ "env", sanitize_label_value e ]
;;

(* CODE_LAYER-016: render per-workload volumes as a PVC per declared volume plus
   container [volumeMounts] and pod [volumes] entries. StorageClass, snapshots,
   and backup policy stay out of scope. *)
let volume_claim_name ~name ~volume_name = Printf.sprintf "%s-%s" name volume_name

let pvc_docs ~ns ~name volumes =
  volumes
  |> List.map (fun (v : Sol_cli_toml.volume) ->
    resource
      ~api_version:"v1"
      ~kind:"PersistentVolumeClaim"
      [ "metadata", metadata ~ns ~name:(volume_claim_name ~name ~volume_name:v.name)
      ; ( "spec"
        , Y.map
            [ ( "accessModes"
              , Y.list
                  [ Y.string (Sol_cli_toml.volume_access_mode_to_string v.access_mode) ] )
            ; "resources", Y.map [ "requests", Y.map [ "storage", Y.string v.size ] ]
            ] )
      ])
;;

(* AUDIT-080: the framework drain timeout is 30s (sol-svc/sol-worker), and
   Kubernetes' own default grace is 30s -- the two race. Sol renders a grace
   that is strictly larger than the drain bound so SIGTERM always has room to
   finish, independent of the primitive. *)
let default_termination_grace_seconds = 45

let probe ~path ~port settings =
  Y.map
    (("httpGet", Y.map [ "path", Y.string path; "port", Y.int port ])
     :: List.map (fun (key, n) -> key, Y.int n) settings)
;;

let container_port = function
  | Http_service -> 8080
  | Background_worker -> 9090
;;

(* AUDIT-080: the probes a workload can honestly claim. An HTTP service is
   healthy when it answers; a Kafka consumer is *ready* when its partitions
   are assigned and *live* while it keeps polling, which is a different
   statement from "the process is up" -- a hung consumer must be replaced. A
   worker that consumes nothing has no observable consumer state, so Sol
   renders no liveness/readiness claim rather than a default that asserts
   nothing. A progressive rollout uses the same policy: it must not weaken the
   availability claim the app declared. *)
let probes ~shape ~consumes_kafka ~readiness_path =
  match shape, consumes_kafka with
  | Http_service, _ ->
    (* INFRA-073: readiness is /readyz, which sol-svc turns 503 as shutdown
       begins; liveness and startup stay on /healthz. A TypeScript service
       renders /healthz until its framework serves /readyz (FEAT-096). *)
    [ ( "startupProbe"
      , probe ~path:"/healthz" ~port:8080 [ "failureThreshold", 30; "periodSeconds", 5 ] )
    ; ( "livenessProbe"
      , probe
          ~path:"/healthz"
          ~port:8080
          [ "initialDelaySeconds", 5; "periodSeconds", 10 ] )
    ; ( "readinessProbe"
      , probe
          ~path:readiness_path
          ~port:8080
          [ "initialDelaySeconds", 5; "periodSeconds", 10 ] )
    ]
  | Background_worker, true ->
    [ ( "startupProbe"
      , probe ~path:"/readyz" ~port:9090 [ "failureThreshold", 60; "periodSeconds", 5 ] )
    ; "readinessProbe", probe ~path:"/readyz" ~port:9090 [ "periodSeconds", 10 ]
    ; ( "livenessProbe"
      , probe ~path:"/livez" ~port:9090 [ "periodSeconds", 10; "failureThreshold", 3 ] )
    ]
  | Background_worker, false -> []
;;

let non_root_pod_security =
  Y.map
    [ "runAsNonRoot", Y.bool true
    ; "runAsUser", Y.int 65534
    ; "runAsGroup", Y.int 65534
    ; "seccompProfile", Y.map [ "type", Y.string "RuntimeDefault" ]
    ]
;;

let container_security =
  Y.map
    [ "allowPrivilegeEscalation", Y.bool false; "readOnlyRootFilesystem", Y.bool true ]
;;

let env_from ~name =
  Y.list
    [ Y.map [ "configMapRef", Y.map [ "name", Y.string (name ^ "-env") ] ]
    ; Y.map [ "secretRef", Y.map [ "name", Y.string (workload_secret_name name) ] ]
    ]
;;

let resources ~cpu ~memory =
  let quantities = Y.map [ "cpu", Y.string cpu; "memory", Y.string memory ] in
  Y.map [ "requests", quantities; "limits", quantities ]
;;

(* [items] as a field only when there are any: Kubernetes reads an absent list
   and an empty one alike, and the manifests have never carried empty ones. *)
let non_empty_list key = function
  | [] -> []
  | items -> [ key, Y.list items ]
;;

(* The pod template a Deployment and an Argo Rollout share: only the enclosing
   kind, apiVersion and strategy differ between the two. *)
let pod_template
      ~extra_labels
      ~secret_keys
      ~volumes
      ~env
      ~config_hash
      ~availability
      ~consumes_kafka
      ~readiness_path
      ~shape
      ~cpu
      ~memory
      ~name
      ~image
      ~workspace
      ~domain
      ~primitive
      ~release_id
  =
  let port = container_port shape in
  let labels =
    ("app", Y.string name)
    :: (taxonomy_labels ?env ~workspace ~domain ~service:name ~primitive ~release_id ()
        @ extra_labels
        |> List.map (fun (k, v) -> k, Y.quoted v))
  in
  let annotations =
    quoted_map
      [ "sol.dev/config-hash", config_hash
      ; "prometheus.io/scrape", "true"
      ; "prometheus.io/port", string_of_int port
      ]
  in
  (* AUDIT-080: spread a node-failure-tolerant workload across nodes, so losing
     one node cannot take every replica with it. The pod anti-affinity is
     expressed as a hard spread: the claim is a guarantee, not a preference. *)
  let spread =
    if Sol_cli_availability.is_node_failure_tolerant availability
    then
      [ ( "topologySpreadConstraints"
        , Y.list
            [ Y.map
                [ "maxSkew", Y.int 1
                ; "topologyKey", Y.string "kubernetes.io/hostname"
                ; "whenUnsatisfiable", Y.string "DoNotSchedule"
                ; "labelSelector", Y.map [ "matchLabels", app_selector name ]
                ]
            ] )
      ]
    else []
  in
  let pod_volumes =
    volumes
    |> List.map (fun (v : Sol_cli_toml.volume) ->
      Y.map
        [ "name", Y.string v.name
        ; ( "persistentVolumeClaim"
          , Y.map [ "claimName", Y.string (volume_claim_name ~name ~volume_name:v.name) ]
          )
        ])
  in
  let volume_mounts =
    volumes
    |> List.map (fun (v : Sol_cli_toml.volume) ->
      Y.map [ "name", Y.string v.name; "mountPath", Y.string v.mount_path ])
  in
  let container =
    Y.map
      ([ "name", Y.string name
       ; "image", Y.string image
       ; "imagePullPolicy", Y.string "Always"
       ; "securityContext", container_security
       ; "ports", Y.list [ Y.map [ "containerPort", Y.int port ] ]
       ]
       @ non_empty_list "volumeMounts" volume_mounts
       @ non_empty_list "env" (secret_key_refs ~name secret_keys)
       @ [ "envFrom", env_from ~name; "resources", resources ~cpu ~memory ]
       @ probes ~shape ~consumes_kafka ~readiness_path)
  in
  Y.map
    [ "metadata", Y.map [ "labels", Y.map labels; "annotations", annotations ]
    ; ( "spec"
      , Y.map
          ([ "serviceAccountName", Y.string name
           ; "securityContext", non_root_pod_security
           ; "terminationGracePeriodSeconds", Y.int default_termination_grace_seconds
           ]
           @ spread
           @ non_empty_list "volumes" pod_volumes
           @ [ "containers", Y.list [ container ] ]) )
    ]
;;

let deployment_doc
      ?(rollout_strategy = Sol_cli_toml.RollingUpdate)
      ?(extra_labels = [])
      ?(secret_keys = [])
      ?(volumes = [])
      ?env
      ?(availability = Sol_cli_availability.Single)
      ?(consumes_kafka = false)
      ?(readiness_path = "/readyz")
      ~config_hash
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
  let strategy_type =
    match rollout_strategy with
    | Sol_cli_toml.Recreate -> "Recreate"
    | Sol_cli_toml.RollingUpdate -> "RollingUpdate"
  in
  resource
    ~api_version:"apps/v1"
    ~kind:"Deployment"
    [ "metadata", metadata ~ns ~name
    ; ( "spec"
      , Y.map
          [ "replicas", Y.int replicas
          ; "strategy", Y.map [ "type", Y.string strategy_type ]
          ; "selector", Y.map [ "matchLabels", app_selector name ]
          ; ( "template"
            , pod_template
                ~extra_labels
                ~secret_keys
                ~volumes
                ~env
                ~config_hash
                ~availability
                ~consumes_kafka
                ~readiness_path
                ~shape
                ~cpu
                ~memory
                ~name
                ~image
                ~workspace
                ~domain
                ~primitive
                ~release_id )
          ] )
    ]
;;

(* AUDIT-080: a node-failure-tolerant workload gets a voluntary-disruption
   budget so a drain cannot evict every ready replica at once. Rendered only for
   that claim -- a [single] workload has no tolerance to protect. *)
let pdb_doc ~ns ~name ~replicas =
  resource
    ~api_version:"policy/v1"
    ~kind:"PodDisruptionBudget"
    [ "metadata", metadata ~ns ~name
    ; ( "spec"
      , Y.map
          [ "minAvailable", Y.int (max 1 (replicas - 1))
          ; "selector", Y.map [ "matchLabels", app_selector name ]
          ] )
    ]
;;

(* ── Argo Rollouts ────────────────────────────────────────────────────────── *)

let canary_step = function
  | Sol_cli_toml.Weight n -> Y.map [ "setWeight", Y.int n ]
  | Sol_cli_toml.Pause None -> Y.map [ "pause", Y.map [] ]
  | Sol_cli_toml.Pause (Some d) -> Y.map [ "pause", Y.map [ "duration", Y.int d ] ]
;;

let rollout_strategy ~name = function
  | Sol_cli_toml.Canary { steps } ->
    Y.map [ "canary", Y.map [ "steps", Y.list (List.map canary_step steps) ] ]
  | Sol_cli_toml.Blue_green ->
    Y.map
      [ ( "blueGreen"
        , Y.map
            [ "activeService", Y.string (name ^ "-active")
            ; "previewService", Y.string (name ^ "-preview")
            ; "autoPromotionEnabled", Y.bool false
            ] )
      ]
;;

(** [rollout_doc] renders an Argo Rollout resource instead of a Deployment. The
    pod template is the same as a Deployment's; only the top-level kind,
    apiVersion, and strategy differ. *)
let rollout_doc
      ?(extra_labels = [])
      ?(secret_keys = [])
      ?(volumes = [])
      ?env
      ?(availability = Sol_cli_availability.Single)
      ?(consumes_kafka = false)
      ?(readiness_path = "/readyz")
      ~config_hash
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
  resource
    ~api_version:"argoproj.io/v1alpha1"
    ~kind:"Rollout"
    [ "metadata", metadata ~ns ~name
    ; ( "spec"
      , Y.map
          [ "replicas", Y.int replicas
          ; "selector", Y.map [ "matchLabels", app_selector name ]
          ; ( "template"
            , pod_template
                ~extra_labels
                ~secret_keys
                ~volumes
                ~env
                ~config_hash
                ~availability
                ~consumes_kafka
                ~readiness_path
                ~shape
                ~cpu
                ~memory
                ~name
                ~image
                ~workspace
                ~domain
                ~primitive
                ~release_id )
          ; "strategy", rollout_strategy ~name pd
          ] )
    ]
;;

(* ── Services and ingress ─────────────────────────────────────────────────── *)

let service_doc ~ns ~name =
  resource
    ~api_version:"v1"
    ~kind:"Service"
    [ "metadata", metadata ~ns ~name
    ; ( "spec"
      , Y.map
          [ "type", Y.string "ClusterIP"
          ; "selector", app_selector name
          ; "ports", Y.list [ Y.map [ "port", Y.int 80; "targetPort", Y.int 8080 ] ]
          ] )
    ]
;;

(** Two ClusterIP Services required by the blue-green strategy: [<name>-active]
    receives live traffic; [<name>-preview] receives canary traffic. Both select
    pods with the [app: <name>] label — Argo manages the selector patch. *)
let blue_green_service_docs ~ns ~name =
  let service suffix =
    resource
      ~api_version:"v1"
      ~kind:"Service"
      [ "metadata", metadata ~ns ~name:(name ^ suffix)
      ; ( "spec"
        , Y.map
            [ "type", Y.string "ClusterIP"
            ; "selector", app_selector name
            ; "ports", Y.list [ Y.map [ "port", Y.int 80; "targetPort", Y.int 8080 ] ]
            ] )
      ]
  in
  [ service "-active"; service "-preview" ]
;;

let ingress_doc
      ?ingress_host
      ?(ingress_path = "/")
      ?(cluster_issuer = "letsencrypt-prod")
      ?tls_secret_name
      ~ns
      ~name
      ()
  =
  (* BUG-021: never emit a hostless rule. nginx matches on host+path and its
     admission webhook rejects a duplicate host+path cluster-wide, so two
     services without an ingress_host (or two workspaces sharing `sol-local`)
     collided on host "" + path "/" and broke `sol up`. Give each a
     per-service dev host instead; including the namespace keeps it unique
     when several workspaces share a cluster. It is HTTP-only -- the TLS,
     cert-manager, and ssl-redirect bits below stay off unless a real
     `ingress_host` was declared. *)
  let host =
    match ingress_host with
    | Some host -> host
    | None -> Printf.sprintf "%s.%s.localhost" name ns
  in
  let annotations, tls =
    match ingress_host with
    | None -> [], []
    | Some host ->
      let secret_name = Option.value tls_secret_name ~default:(name ^ "-tls") in
      ( [ ( "annotations"
          , Y.map
              [ "cert-manager.io/cluster-issuer", Y.string cluster_issuer
              ; "nginx.ingress.kubernetes.io/ssl-redirect", Y.quoted "true"
              ] )
        ]
      , [ ( "tls"
          , Y.list
              [ Y.map
                  [ "hosts", Y.list [ Y.string host ]
                  ; "secretName", Y.string secret_name
                  ]
              ] )
        ] )
  in
  let rule =
    Y.map
      [ "host", Y.string host
      ; ( "http"
        , Y.map
            [ ( "paths"
              , Y.list
                  [ Y.map
                      [ "path", Y.string ingress_path
                      ; "pathType", Y.string "Prefix"
                      ; ( "backend"
                        , Y.map
                            [ ( "service"
                              , Y.map
                                  [ "name", Y.string name
                                  ; "port", Y.map [ "number", Y.int 80 ]
                                  ] )
                            ] )
                      ]
                  ] )
            ] )
      ]
  in
  resource
    ~api_version:"networking.k8s.io/v1"
    ~kind:"Ingress"
    [ "metadata", Y.map ([ "name", Y.string name; "namespace", Y.string ns ] @ annotations)
    ; ( "spec"
      , Y.map
          ([ "ingressClassName", Y.string "nginx" ] @ tls @ [ "rules", Y.list [ rule ] ])
      )
    ]
;;

let namespace_selector ns =
  Y.map
    [ ( "namespaceSelector"
      , Y.map [ "matchLabels", Y.map [ "kubernetes.io/metadata.name", Y.string ns ] ] )
    ]
;;

(* One peer: a namespace and a pod within it, as one selector. *)
let peer ~ns ~name =
  Y.map
    [ ( "namespaceSelector"
      , Y.map [ "matchLabels", Y.map [ "kubernetes.io/metadata.name", Y.string ns ] ] )
    ; "podSelector", Y.map [ "matchLabels", app_selector name ]
    ]
;;

let network_policy_doc ?(egress_to = []) ?(ingress_from = []) ~ns ~name () =
  let platform_ingress =
    Y.map
      [ ( "from"
        , Y.list
            [ namespace_selector "ingress-nginx"
            ; namespace_selector "monitoring"
            ; Y.map [ "podSelector", Y.map [] ]
            ] )
      ]
  in
  let caller_ingress (from_ns, from_name) =
    Y.map
      [ "from", Y.list [ peer ~ns:from_ns ~name:from_name ]
      ; "ports", Y.list [ Y.map [ "port", Y.int 8080 ] ]
      ]
  in
  let dns_egress =
    Y.map
      [ ( "ports"
        , Y.list
            [ Y.map [ "port", Y.int 53; "protocol", Y.string "UDP" ]
            ; Y.map [ "port", Y.int 53; "protocol", Y.string "TCP" ]
            ] )
      ]
  in
  let platform_egress =
    Y.map
      [ ( "to"
        , Y.list
            [ namespace_selector "redpanda"
            ; namespace_selector "postgresql"
            ; namespace_selector "monitoring"
            ] )
      ]
  in
  (* No `ports:` on a callee, deliberately. Egress policy is evaluated on the
     packet leaving the caller, before kube-proxy DNATs the Service ClusterIP --
     so a port restriction would have to name the target's *Service* port (80),
     not its container port (8080). A CNI that instead matches post-DNAT would
     need 8080, so no single number is portable. Scoping by the target pod
     (namespace + app) with no port restriction is what the platform dependency
     rules above already do, and it works under either interpretation. The
     ingress side keeps 8080 because ingress is always evaluated after DNAT,
     against the target pod's real port. *)
  let callee_egress (to_ns, to_name) =
    Y.map [ "to", Y.list [ peer ~ns:to_ns ~name:to_name ] ]
  in
  resource
    ~api_version:"networking.k8s.io/v1"
    ~kind:"NetworkPolicy"
    [ "metadata", metadata ~ns ~name:(name ^ "-netpol")
    ; ( "spec"
      , Y.map
          [ "podSelector", Y.map [ "matchLabels", app_selector name ]
          ; "policyTypes", Y.list [ Y.string "Ingress"; Y.string "Egress" ]
          ; "ingress", Y.list (platform_ingress :: List.map caller_ingress ingress_from)
          ; ( "egress"
            , Y.list (dns_egress :: platform_egress :: List.map callee_egress egress_to) )
          ] )
    ]
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
  let labels =
    ("app", Y.string name)
    :: (taxonomy_labels
          ?env
          ~workspace
          ~domain
          ~service:name
          ~primitive:"fn"
          ~release_id
          ()
        |> List.map (fun (k, v) -> k, Y.quoted v))
  in
  let container =
    Y.map
      ([ "name", Y.string name
       ; "image", Y.string image
       ; "imagePullPolicy", Y.string "Always"
       ; "securityContext", container_security
       ]
       @ non_empty_list "env" (secret_key_refs ~name secret_keys)
       @ [ "envFrom", env_from ~name; "resources", resources ~cpu ~memory ])
  in
  resource
    ~api_version:"batch/v1"
    ~kind:"CronJob"
    [ "metadata", metadata ~ns ~name
    ; ( "spec"
      , Y.map
          [ "schedule", Y.quoted schedule
          ; "concurrencyPolicy", Y.string concurrency_policy
          ; ( "jobTemplate"
            , Y.map
                [ ( "spec"
                  , Y.map
                      [ "backoffLimit", Y.int backoff_limit
                      ; ( "template"
                        , Y.map
                            [ "metadata", Y.map [ "labels", Y.map labels ]
                            ; ( "spec"
                              , Y.map
                                  [ "serviceAccountName", Y.string name
                                  ; "restartPolicy", Y.string "OnFailure"
                                  ; "securityContext", non_root_pod_security
                                  ; "containers", Y.list [ container ]
                                  ] )
                            ] )
                      ] )
                ] )
          ] )
    ]
;;

(* ── Migrations ───────────────────────────────────────────────────────────── *)

(* ponytail: a ConfigMap has a 1MiB total size cap -- fine for typical
   migration sets, but a workspace with unusually large SQL files could
   exceed it. Move to a projected volume backed by multiple ConfigMaps (or
   an init-container that fetches files another way) if that ever bites.

   Migration file contents are arbitrary SQL, so every one is quoted: the
   emitter escapes every control character, and a CRLF-terminated file keeps
   its carriage returns rather than having them folded into spaces. *)
let migration_configmap_doc ~name ~namespace files =
  resource
    ~api_version:"v1"
    ~kind:"ConfigMap"
    [ "metadata", metadata ~ns:namespace ~name; "data", quoted_map files ]
;;

(* INFRA-040: the Job reads the workspace's shared runtime Secret by
   [runtime_secret_name] -- the same constant the substrate creates it under, so
   the two cannot disagree. Each argument is one quoted scalar, so a value (a
   table name, a path) cannot change the argument structure. *)
let migration_job_doc ~name ~namespace ~image ~args ~configmap_name =
  let container =
    Y.map
      [ "name", Y.string "migrate"
      ; "image", Y.string image
      ; "args", Y.list (List.map Y.quoted args)
      ; ( "envFrom"
        , Y.list [ Y.map [ "secretRef", Y.map [ "name", Y.string runtime_secret_name ] ] ]
        )
      ; ( "volumeMounts"
        , Y.list
            [ Y.map [ "name", Y.string "migrations"; "mountPath", Y.string "/migrations" ]
            ] )
      ]
  in
  resource
    ~api_version:"batch/v1"
    ~kind:"Job"
    [ "metadata", metadata ~ns:namespace ~name
    ; ( "spec"
      , Y.map
          [ "backoffLimit", Y.int 0
          ; ( "template"
            , Y.map
                [ ( "spec"
                  , Y.map
                      [ "restartPolicy", Y.string "Never"
                      ; "containers", Y.list [ container ]
                      ; ( "volumes"
                        , Y.list
                            [ Y.map
                                [ "name", Y.string "migrations"
                                ; "configMap", Y.map [ "name", Y.string configmap_name ]
                                ]
                            ] )
                      ] )
                ] )
          ] )
    ]
;;
