open Result.Syntax

type component =
  | Redpanda
  | Postgresql
  | Loki
  | Grafana
  | Tempo
  | Prometheus

let name = function
  | Redpanda -> "redpanda"
  | Postgresql -> "postgresql"
  | Loki -> "loki"
  | Grafana -> "grafana"
  | Tempo -> "tempo"
  | Prometheus -> "prometheus"
;;

type component_values =
  { redpanda : string
  ; postgresql : string
  ; loki : string
  ; grafana : string
  ; tempo : string
  ; prometheus : string
  }

let value (values : component_values) = function
  | Redpanda -> values.redpanda
  | Postgresql -> values.postgresql
  | Loki -> values.loki
  | Grafana -> values.grafana
  | Tempo -> values.tempo
  | Prometheus -> values.prometheus
;;

type assets =
  { component_values : component_values
  ; alloy_values : string
  ; dashboards : string
  }

let read_component ~platform_assets component =
  Sol_cli_platform_component.merged_values_yaml
    ~assets:platform_assets
    ~component:(name component)
    ~profile:"local"
;;

let read_assets () =
  let* assets =
    Sol_cli_platform_assets.resolve ()
    |> Result.map_error Sol_cli_platform_assets.error_to_string
  in
  let* redpanda = read_component ~platform_assets:assets Redpanda in
  let* postgresql = read_component ~platform_assets:assets Postgresql in
  let* loki = read_component ~platform_assets:assets Loki in
  let* grafana = read_component ~platform_assets:assets Grafana in
  let* tempo = read_component ~platform_assets:assets Tempo in
  let* prometheus = read_component ~platform_assets:assets Prometheus in
  let* alloy_values = Sol_cli_dev_observability.alloy_values_yaml ~assets in
  let* dashboards =
    Sol_cli_dev_observability.dashboard_configmap_yaml ~assets ~namespace:"monitoring"
  in
  Ok
    { component_values = { redpanda; postgresql; loki; grafana; tempo; prometheus }
    ; alloy_values
    ; dashboards
    }
;;

let values_of assets component = value assets.component_values component

let needs_grafana (req : Sol_cli_workspace.infra_requirements) =
  req.loki || req.prometheus || req.tempo
;;

let needs_any_chart (req : Sol_cli_workspace.infra_requirements) =
  req.kafka || req.postgres || needs_grafana req
;;

let repositories =
  [ "redpanda", "https://charts.redpanda.com"
  ; "ingress-nginx", "https://kubernetes.github.io/ingress-nginx"
  ; "grafana", "https://grafana.github.io/helm-charts"
  ; "grafana-community", "https://grafana-community.github.io/helm-charts"
  ; "bitnami", "https://charts.bitnami.com/bitnami"
  ; "prometheus-community", "https://prometheus-community.github.io/helm-charts"
  ]
;;

type release =
  { label : string
  ; name : string
  ; chart : string
  ; namespace : string
  ; version : string option
  ; values : (string * Sol_cli_helm.set_val) list
  ; values_yaml : string option
  }

let releases ~(req : Sol_cli_workspace.infra_requirements) ~assets =
  let open Sol_cli_helm in
  let need_grafana = needs_grafana in
  let release ~label name chart ~namespace ?version ?(values = []) ?values_yaml () =
    { label; name; chart; namespace; version; values; values_yaml }
  in
  let kafka_releases =
    if req.kafka
    then
      [ release
          ~label:"Redpanda"
          "redpanda"
          "redpanda/redpanda"
          ~namespace:"redpanda"
          ~version:"26.1.11"
          ~values:
            [ "storage.persistentVolume.size", Str "1Gi"
            ; "external.enabled", Bool true
            ; "external.service.enabled", Bool false
            ; "external.addresses[0]", Str "localhost"
            ; "listeners.kafka.external.default.advertisedPorts[0]", Float 9092.
            ]
          ~values_yaml:(values_of assets Redpanda)
          ()
      ]
    else []
  in
  let postgres_releases =
    if req.postgres
    then
      [ release
          ~label:"PostgreSQL"
          "postgresql"
          "bitnami/postgresql"
          ~namespace:"postgresql"
          ~version:"18.8.17"
          ~values_yaml:(values_of assets Postgresql)
          ()
      ]
    else []
  in
  let observability_releases =
    if need_grafana req
    then
      [ release
          ~label:"Loki"
          "loki"
          "grafana-community/loki"
          ~namespace:"monitoring"
          ~version:"18.12.1"
          ~values_yaml:(values_of assets Loki)
          ()
      ; release
          ~label:"Grafana"
          "grafana"
          "grafana-community/grafana"
          ~namespace:"monitoring"
          ~version:"13.2.1"
          ~values:[ "adminPassword", Str "dev" ]
          ~values_yaml:(values_of assets Grafana)
          ()
      ; release
          ~label:"Alloy"
          "alloy"
          "grafana/alloy"
          ~namespace:"monitoring"
          ~version:"1.12.1"
          ~values_yaml:assets.alloy_values
          ()
      ]
    else []
  in
  let tempo_releases =
    if req.tempo
    then
      [ release
          ~label:"Tempo"
          "tempo"
          "grafana-community/tempo"
          ~namespace:"monitoring"
          ~version:"2.3.0"
          ~values_yaml:(values_of assets Tempo)
          ()
      ]
    else []
  in
  let prometheus_releases =
    if req.prometheus
    then
      [ release
          ~label:"Prometheus"
          "prometheus"
          "prometheus-community/prometheus"
          ~namespace:"monitoring"
          ~version:"25.20.1"
          ~values:[ "prometheus-node-exporter.enabled", Bool false ]
          ~values_yaml:(values_of assets Prometheus)
          ()
      ]
    else []
  in
  let ingress_releases =
    [ release
        ~label:"ingress-nginx"
        "ingress-nginx"
        "ingress-nginx/ingress-nginx"
        ~namespace:"ingress-nginx"
        ~version:"4.10.1"
        ~values:[ "controller.service.type", Str "NodePort" ]
        ()
    ]
  in
  List.concat
    [ kafka_releases
    ; postgres_releases
    ; observability_releases
    ; tempo_releases
    ; prometheus_releases
    ; ingress_releases
    ]
;;

type endpoint =
  { forward : Sol_cli_port_forward.spec
  ; required : bool
  ; summary : string
  }

let ingress_local_port = 8088
let schema_registry_service = "redpanda"
let schema_registry_remote_port = 8081

let schema_registry_forward =
  { Sol_cli_port_forward.name = "schema-registry"
  ; namespace = schema_registry_service
  ; target = "svc/" ^ schema_registry_service
  ; local_port = 8081
  ; remote_port = schema_registry_remote_port
  }
;;

let schema_registry_summary =
  Printf.sprintf
    "  schema-reg   ✓  http://localhost:%d"
    schema_registry_forward.local_port
;;

let free_local_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
       Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
       match Unix.getsockname socket with
       | Unix.ADDR_INET (_, port) -> port
       | Unix.ADDR_UNIX _ -> 0)
;;

let with_schema_registry_endpoint f =
  let local_port = free_local_port () in
  match
    Sol_cli_kubectl.temporary_port_forward
      ~ctx:Sol_cli_kube_destination.local_context
      ~service:schema_registry_service
      ~namespace:schema_registry_forward.namespace
      ~local_port
      ~remote_port:schema_registry_forward.remote_port
  with
  | Ok () -> f ~url:(Printf.sprintf "http://localhost:%d" local_port)
  | Error (Not_started e) ->
    Error
      ("could not reach the cluster's schema registry ("
       ^ schema_registry_service
       ^ "/"
       ^ schema_registry_service
       ^ ":"
       ^ string_of_int schema_registry_forward.remote_port
       ^ "): "
       ^ Sol_cli_process.error_to_string e)
  | Error Not_ready ->
    Error
      (Printf.sprintf
         "the port-forward to the cluster's schema registry did not become ready on \
          localhost:%d"
         local_port)
  | Error (Readiness_check_failed message) ->
    Error
      ("the schema registry this deploy would register against is not the cluster's: "
       ^ message)
;;

let endpoints ~(req : Sol_cli_workspace.infra_requirements) =
  let endpoint ~required name ~namespace ~target ~local_port ~remote_port summary =
    { forward = { Sol_cli_port_forward.name; namespace; target; local_port; remote_port }
    ; required
    ; summary
    }
  in
  let grafana = needs_grafana req in
  let kafka_endpoints =
    if req.kafka
    then
      [ endpoint
          ~required:req.kafka
          "kafka"
          ~namespace:"redpanda"
          ~target:"pod/redpanda-0"
          ~local_port:9092
          ~remote_port:9094
          "  kafka        ✓  localhost:9092  (port-forwarded)"
      ; { forward = schema_registry_forward
        ; required = req.kafka
        ; summary = schema_registry_summary
        }
      ]
    else []
  in
  let postgres_endpoints =
    if req.postgres
    then
      [ endpoint
          ~required:req.postgres
          "postgres"
          ~namespace:"postgresql"
          ~target:"svc/postgresql"
          ~local_port:5432
          ~remote_port:5432
          "  postgres     ✓  postgresql://postgres:dev@localhost:5432/dev  \
           (port-forwarded)"
      ]
    else []
  in
  let observability_endpoints =
    if grafana
    then
      [ endpoint
          ~required:req.loki
          "loki"
          ~namespace:"monitoring"
          ~target:"svc/loki"
          ~local_port:3100
          ~remote_port:3100
          "  loki         ✓  http://localhost:3100  (port-forwarded)"
      ; endpoint
          ~required:grafana
          "grafana"
          ~namespace:"monitoring"
          ~target:"svc/grafana"
          ~local_port:3000
          ~remote_port:80
          "  grafana      ✓  http://localhost:3000  (port-forwarded)"
      ]
    else []
  in
  let prometheus_endpoints =
    if req.prometheus
    then
      [ endpoint
          ~required:req.prometheus
          "prometheus"
          ~namespace:"monitoring"
          ~target:"svc/prometheus-server"
          ~local_port:9090
          ~remote_port:80
          "  prometheus   ✓  http://localhost:9090  (port-forwarded)"
      ; endpoint
          ~required:req.prometheus
          "pushgateway"
          ~namespace:"monitoring"
          ~target:"svc/prometheus-prometheus-pushgateway"
          ~local_port:9091
          ~remote_port:9091
          "  pushgateway  ✓  http://localhost:9091  (port-forwarded)"
      ]
    else []
  in
  let tempo_endpoints =
    if req.tempo
    then
      [ endpoint
          ~required:req.tempo
          "tempo"
          ~namespace:"monitoring"
          ~target:"svc/tempo"
          ~local_port:4318
          ~remote_port:4318
          "  tempo        ✓  http://localhost:4318  (OTLP, port-forwarded)"
      ; endpoint
          ~required:req.tempo
          "tempo-query"
          ~namespace:"monitoring"
          ~target:"svc/tempo"
          ~local_port:3200
          ~remote_port:3200
          "  tempo-query  ✓  http://localhost:3200  (port-forwarded)"
      ]
    else []
  in
  let ingress_endpoints =
    [ endpoint
        ~required:true
        "ingress"
        ~namespace:"ingress-nginx"
        ~target:"svc/ingress-nginx-controller"
        ~local_port:ingress_local_port
        ~remote_port:80
        (Printf.sprintf
           "  ingress      ✓  http://localhost:%d  (ingress-nginx, port-forwarded)"
           ingress_local_port)
    ]
  in
  List.concat
    [ kafka_endpoints
    ; postgres_endpoints
    ; observability_endpoints
    ; prometheus_endpoints
    ; tempo_endpoints
    ; ingress_endpoints
    ]
;;
