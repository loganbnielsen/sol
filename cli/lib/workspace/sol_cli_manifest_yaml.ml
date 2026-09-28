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

module Workload_spec = struct
  type t =
    { extra_labels : (string * string) list
    ; secret_keys : string list
    ; volumes : Sol_cli_toml.volume list
    ; env : string option
    ; config_hash : string
    ; availability : Sol_cli_availability.t
    ; consumes_kafka : bool
    ; readiness_path : string
    ; shape : workload_shape
    ; replicas : int
    ; cpu : string
    ; memory : string
    ; ns : string
    ; name : string
    ; image : string
    ; workspace : string
    ; domain : string
    ; primitive : string
    ; release_id : Sol_cli_release_id.t
    }
end

let default_cluster_env =
  [ "KAFKA_SECURITY_PROTOCOL", "plaintext"
  ; "KAFKA_BROKERS", "redpanda.redpanda.svc.cluster.local:9093"
  ; "SCHEMA_REGISTRY_URL", "http://redpanda.redpanda.svc.cluster.local:8081"
  ; "REDPANDA_ADMIN_URL", "http://redpanda.redpanda.svc.cluster.local:9644"
  ; "LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100"
  ; ( "PUSHGATEWAY_URL"
    , "http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091" )
  ; "TEMPO_URL", "http://tempo.monitoring.svc.cluster.local:4318"
  ]
;;

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

let deploy_role_binding_doc ~ns =
  role_binding_doc
    ~ns
    ~name:"sol-deploy"
    ~cluster_role:"sol-deploy"
    ~group:"sol:deployers"
;;

let operator_role_binding_doc ~ns =
  role_binding_doc
    ~ns
    ~name:"sol-operator"
    ~cluster_role:"sol-operator-diagnostics"
    ~group:"sol:operators"
;;

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

let workload_secret_name name = Printf.sprintf "%s-secrets" name

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

let sanitize_label_value = Sol_cli_kubernetes_name.sanitize_label_value

let taxonomy_labels ?env ~workspace ~domain ~service ~primitive ~release_id () =
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

let probes ~shape ~consumes_kafka ~readiness_path =
  match shape, consumes_kafka with
  | Http_service, _ ->
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

let non_empty_list key = function
  | [] -> []
  | items -> [ key, Y.list items ]
;;

let pod_template
      { Workload_spec.extra_labels
      ; secret_keys
      ; volumes
      ; env
      ; config_hash
      ; availability
      ; consumes_kafka
      ; readiness_path
      ; shape
      ; cpu
      ; memory
      ; name
      ; image
      ; workspace
      ; domain
      ; primitive
      ; release_id
      ; _
      }
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

let deployment_doc ?(rollout_strategy = Sol_cli_toml.RollingUpdate) ~workload () =
  let { Workload_spec.replicas; ns; name; _ } = workload in
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
          ; "template", pod_template workload
          ] )
    ]
;;

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

let rollout_doc ~workload ~pd () =
  let { Workload_spec.replicas; ns; name; _ } = workload in
  resource
    ~api_version:"argoproj.io/v1alpha1"
    ~kind:"Rollout"
    [ "metadata", metadata ~ns ~name
    ; ( "spec"
      , Y.map
          [ "replicas", Y.int replicas
          ; "selector", Y.map [ "matchLabels", app_selector name ]
          ; "template", pod_template workload
          ; "strategy", rollout_strategy ~name pd
          ] )
    ]
;;

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

module Scheduled_workload_spec = struct
  type t =
    { ns : string
    ; name : string
    ; image : string
    ; secret_keys : string list
    ; env : string option
    ; schedule : string
    ; concurrency_policy : string
    ; backoff_limit : int
    ; cpu : string
    ; memory : string
    ; workspace : string
    ; domain : string
    ; release_id : Sol_cli_release_id.t
    }
end

let cronjob_doc (workload : Scheduled_workload_spec.t) =
  let open Scheduled_workload_spec in
  let { ns
      ; name
      ; image
      ; secret_keys
      ; env
      ; schedule
      ; concurrency_policy
      ; backoff_limit
      ; cpu
      ; memory
      ; workspace
      ; domain
      ; release_id
      }
    =
    workload
  in
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

let migration_configmap_doc ~name ~namespace files =
  resource
    ~api_version:"v1"
    ~kind:"ConfigMap"
    [ "metadata", metadata ~ns:namespace ~name; "data", quoted_map files ]
;;

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
