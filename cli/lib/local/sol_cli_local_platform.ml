open Result.Syntax

type assets =
  { component_values : (string * string) list
  ; alloy_values : string
  ; dashboards : string
  }

let components = [ "redpanda"; "postgresql"; "loki"; "grafana"; "tempo"; "prometheus" ]

let read_assets () =
  let* assets =
    Sol_cli_platform_assets.resolve ()
    |> Result.map_error Sol_cli_platform_assets.error_to_string
  in
  let* component_values =
    components
    |> Sol_cli_result.map_list (fun component ->
      Sol_cli_platform_component.merged_values_yaml ~assets ~component ~profile:"local"
      |> Result.map (fun values -> component, values))
  in
  let* alloy_values = Sol_cli_dev_observability.alloy_values_yaml ~assets in
  let* dashboards =
    Sol_cli_dev_observability.dashboard_configmap_yaml ~assets ~namespace:"monitoring"
  in
  Ok { component_values; alloy_values; dashboards }
;;

let values_of assets component = List.assoc component assets.component_values

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
          ~values_yaml:(values_of assets "redpanda")
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
          ~values_yaml:(values_of assets "postgresql")
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
          ~values_yaml:(values_of assets "loki")
          ()
      ; release
          ~label:"Grafana"
          "grafana"
          "grafana-community/grafana"
          ~namespace:"monitoring"
          ~version:"13.2.1"
          ~values:[ "adminPassword", Str "dev" ]
          ~values_yaml:(values_of assets "grafana")
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
          ~values_yaml:(values_of assets "tempo")
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
          ~values_yaml:(values_of assets "prometheus")
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
  ; summary : string
  }

let ingress_local_port = 8088

let endpoints ~(req : Sol_cli_workspace.infra_requirements) =
  let endpoint name ~namespace ~target ~local_port ~remote_port summary =
    { forward = { Sol_cli_port_forward.name; namespace; target; local_port; remote_port }
    ; summary
    }
  in
  let grafana = needs_grafana req in
  let kafka_endpoints =
    if req.kafka
    then
      [ endpoint
          "kafka"
          ~namespace:"redpanda"
          ~target:"pod/redpanda-0"
          ~local_port:9092
          ~remote_port:9094
          "  kafka        ✓  localhost:9092  (port-forwarded)"
      ; endpoint
          "schema-registry"
          ~namespace:"redpanda"
          ~target:"svc/redpanda"
          ~local_port:8081
          ~remote_port:8081
          "  schema-reg   ✓  http://localhost:8081"
      ]
    else []
  in
  let postgres_endpoints =
    if req.postgres
    then
      [ endpoint
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
          "loki"
          ~namespace:"monitoring"
          ~target:"svc/loki"
          ~local_port:3100
          ~remote_port:3100
          "  loki         ✓  http://localhost:3100  (port-forwarded)"
      ; endpoint
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
          "prometheus"
          ~namespace:"monitoring"
          ~target:"svc/prometheus-server"
          ~local_port:9090
          ~remote_port:80
          "  prometheus   ✓  http://localhost:9090  (port-forwarded)"
      ; endpoint
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
          "tempo"
          ~namespace:"monitoring"
          ~target:"svc/tempo"
          ~local_port:4318
          ~remote_port:4318
          "  tempo        ✓  http://localhost:4318  (OTLP, port-forwarded)"
      ; endpoint
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
