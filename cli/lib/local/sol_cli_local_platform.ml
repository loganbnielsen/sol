(* REFAC-139, part B: what `sol local infra up` installs, as data.

   The releases -- chart, pinned version and values for each component a
   workspace needs -- are a decision, so they live here where a test can read
   them; `cmd_local.ml` installs what this returns and reports it. The comments
   are the pins' rationale and moved with them. *)

open Result.Syntax

(* REFAC-115: everything `sol local infra up` reads from Sol's own assets, read
   and checked before anything is installed -- a missing or malformed asset fails
   here, not halfway through the installs. *)
type assets =
  { component_values : (string * string) list (** component -> merged local values *)
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

(* The chart repositories, added once, before any install runs: a repository is
   shared mutable state in helm's own config, and must not be written while
   installs are running. Alloy stays on grafana; loki/grafana/tempo moved to
   grafana-community (OBS-039). *)
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
  List.concat
    [ (if req.kafka
       then
         [ (* CODE_LAYER-010: values come from
       platform/shared/components.json (redpanda.{common,local})
       (ADR 0001), shared with platform/cloud/modules/platform/main.tf --
       tls.enabled/config.cluster.auto_create_topics_enabled
       (the common layer) and statefulset.replicas/resources.cpu.cores
       (the local layer, for cmd_local.ml's benefit only -- main.tf's own
       var-driven override in its trailing values-list entry always wins
       there, same shadowing pattern as Loki's persistence knob).

       storage.persistentVolume.size and the external.*/listeners.kafka.*
       block stay inline OCaml literals, NOT in the shared JSON: adversarial
       review on this ticket caught that main.tf's own override block
       doesn't touch either, so putting them in the local layer would
       have silently shipped a 20x-undersized PVC (chart default 20Gi ->
       1Gi) and a broken external Kafka listener (every real client would
       be told to reconnect to "localhost") to any real `terraform apply`
       that doesn't opt into self_hosted_durable -- exactly the class of
       bug this whole ADR exists to prevent, just inverted (over-sharing
       instead of under-sharing). These four keys genuinely have no
       main.tf equivalent (real clusters don't need a port-forward-
       compatible external listener, and main.tf never sets a PV size at
       all), matching Grafana's adminPassword/Prometheus's
       node-exporter.enabled precedent for content that stays local-only
       precisely because nothing shields it on the Terraform side. *)
           release
             ~label:"Redpanda"
             "redpanda"
             "redpanda/redpanda"
             ~namespace:"redpanda"
               (* FRIC-007: 5.8.12 (image v24.1.8) predated JSON Schema Registry
         support, which landed in Redpanda 24.2 (redpanda-data/redpanda#6220)
         -- every generated Sol service's unconditional `schemaType: "JSON"`
         registration call got HTTP 422 "Invalid schema type JSON" against it,
         permanently crash-looping every -svc/-worker on a fresh substrate.
         5.9.15 (image v24.2.7) was the smallest bump that provably fixed that
         (verified live: a standalone v24.2.7 broker accepts the identical
         registration call with HTTP 200).

         FRIC-010 then evaluated a further modernization and declined it: an
         in-place upgrade from v24.2.7 to a 26.x binary fails Redpanda's own
         logical-version check ("Attempted to upgrade from incompatible logical
         version 13 to logical version 18") -- a broker-side upgrade-path
         constraint, not a values problem. That was the right call while 5.9.15
         stayed installable.

         INFRA-013: upstream retired the whole 5.x line from the
         charts.redpanda.com index in 2026-09, so `--version 5.9.15` no longer
         resolves and a fresh `sol local infra up` could not install a substrate at
         all. That removed the option FRIC-010 preserved, so the pin moves to
         26.1.11 (image v26.1.17): FRIC-010's evaluated target, one minor behind
         newest, within support, and confirmed to render cleanly against
         the common layer/the local layer (the console.* schema workaround
         is still required upstream). A cluster still on v24.2.7 must be
         recreated rather than upgraded in place -- see INFRA-013.
         CODE_LAYER-008: matches platform/cloud/modules/platform/main.tf's pin. *)
             ~version:"26.1.11"
             ~values:
               [ "storage.persistentVolume.size", Str "1Gi"
               ; (* Advertise localhost:9092 so librdkafka reconnects to the port-forward
           after bootstrap instead of the unresolvable internal cluster DNS. *)
                 "external.enabled", Bool true
               ; "external.service.enabled", Bool false
               ; "external.addresses[0]", Str "localhost"
               ; "listeners.kafka.external.default.advertisedPorts[0]", Float 9092.
               ]
             ~values_yaml:(values_of assets "redpanda")
             ()
         ]
       else [])
    ; (if req.postgres
       then
         [ release
             ~label:"PostgreSQL"
             "postgresql"
             "bitnami/postgresql"
             ~namespace:"postgresql"
               (* CODE_LAYER-008: matches platform/cloud/modules/platform/main.tf's pin. Not
         15.5.1 -- confirmed live that version's default image tag
         (bitnami/postgresql:16.3.0-debian-12-r12) no longer exists on
         Docker Hub; main.tf was bumped to 18.8.17 in the same change (a
         PostgreSQL 16 -> 18 server major-version jump -- see main.tf's
         helm_release.postgresql for the full rationale and the
         image.tag:latest caveat, since Bitnami currently publishes no
         other tag to pin to). Fine for this ephemeral local cluster
         (no persistent volume to be incompatible with -- see below). *)
             ~version:"18.8.17"
               (* CODE_LAYER-010: values come from
         platform/shared/components.json (postgresql.{common,local})
         (ADR 0001) -- auth.database ("dev") is genuinely shared with
         platform/cloud/modules/platform/main.tf; auth.postgresPassword and
         primary.persistence.enabled are dev-only local-profile content
         (main.tf keeps its own var-driven `set` for both -- a real secret
         and an "ephemeral by default" choice matching Loki/Prometheus's
         local profile, neither with a value cmd_local.ml should share). *)
             ~values_yaml:(values_of assets "postgresql")
             ()
         ]
       else [])
    ; (if need_grafana req
       then
         [ (* OBS-039: loki-stack is deprecated (no longer updated/supported per
       Grafana Labs' own chart README) and its bundled Promtail reached
       end-of-life March 2026. Split into the same three charts
       platform/cloud/modules/platform/main.tf uses in production ("Dev mirrors prod
       exactly") -- loki (community-maintained), grafana (standalone), and
       alloy (Promtail's official successor, log-shipping role only). *)
           (* Values come from platform/shared/components.json (loki.{common,local})
       (ADR 0001 / CODE_LAYER-005) -- the same "local" profile
       platform/cloud/modules/platform/main.tf uses for its own non-durable
       observability_backend branch, so a fix like BUG-013's
       replication_factor lands here automatically instead of requiring a
       second, independently-maintained edit (BUG-016). *)
           release
             ~label:"Loki"
             "loki"
             "grafana-community/loki"
             ~namespace:"monitoring"
             ~version:"18.12.1"
               (* CODE_LAYER-008: matches platform/cloud/modules/platform/main.tf's pin *)
             ~values_yaml:(values_of assets "loki")
             ()
         ; (* Values come from platform/shared/components.json (grafana.{common,local})
       (ADR 0001 / CODE_LAYER-005). sidecar.dashboards/datasources: moved
       from loki-stack's nested grafana.sidecar.* passthrough naming to this
       standalone chart's own top-level sidecar.* -- both now need an
       explicit value since this chart (unlike loki-stack) defaults
       sidecar.datasources.enabled to false. *)
           release
             ~label:"Grafana"
             "grafana"
             "grafana-community/grafana"
             ~namespace:"monitoring"
             ~version:"13.2.1"
               (* CODE_LAYER-008: matches platform/cloud/modules/platform/main.tf's pin *)
               (* CODE_LAYER-008: base/main.tf sets adminPassword explicitly
         (var.grafana_admin_password); left at the chart's own default here
         previously, making sol local infra up's Grafana login undocumented and
         chart-version-dependent. Fixed dev-only value, matching
         PostgreSQL's hardcoded "dev" password convention above. *)
             ~values:[ "adminPassword", Str "dev" ]
             ~values_yaml:(values_of assets "grafana")
             ()
         ; (* Cluster-wide pod stdout/stderr scraping via DaemonSet -- same role
       promtail.enabled: true played, so 'sol logs' can fall back to real
       log content even for a pod that crashed before it could push its own
       logs (OBS-004). CODE_LAYER-006: River config is rendered from
       platform/shared/observability/alloy/logs.alloy.tftpl -- the single source,
       shared with platform/cloud/modules/platform/main.tf's own templatefile() call
       for the same file -- instead of a second, hand-synced OCaml copy. *)
           release
             ~label:"Alloy"
             "alloy"
             "grafana/alloy"
             ~namespace:"monitoring"
             ~version:"1.12.1"
               (* CODE_LAYER-008: matches platform/cloud/modules/platform/main.tf's pin *)
             ~values_yaml:assets.alloy_values
             ()
         ]
       else [])
    ; (if req.tempo
       then
         [ (* OBS-042: grafana-community/tempo (not the deprecated grafana/tempo --
       same grafana.github.io -> grafana-community.github.io chart move
       OBS-039 already found for loki/grafana; confirmed via each repo's
       index.yaml `deprecated` field). "Single Binary Mode" is this chart's
       only mode (replicas: 1, no deploymentMode split to zero out the way
       loki's SimpleScalable default requires) -- no extra `set`s needed for
       single-replica local storage, which is already the chart default.
       Spans push to the OTLP/HTTP receiver on port 4318
       (obs-tempo-eio's TEMPO_URL); Grafana's Tempo datasource queries port
       3200. Uses the `grafana-community` repo already added above for
       Loki/Grafana. *)
           (* platform/shared/components.json (tempo) has nothing to say today (both paths
       already agree by relying on the chart's own defaults) -- wiring it up
       anyway locks in the source of truth so the CI guardrail can catch the
       next Tempo value that would otherwise drift, see ADR 0001. *)
           release
             ~label:"Tempo"
             "tempo"
             "grafana-community/tempo"
             ~namespace:"monitoring"
             ~version:"2.3.0"
               (* CODE_LAYER-008: matches platform/cloud/modules/platform/main.tf's pin *)
             ~values_yaml:(values_of assets "tempo")
             ()
         ]
       else [])
    ; (if req.prometheus
       then
         [ (* prometheus-community/prometheus (not kube-prometheus-stack) — lighter weight for dev;
       includes server, alertmanager, pushgateway, kube-state-metrics, node-exporter.
       server.persistentVolume/pushgateway/alertmanager come from
       platform/shared/components.json (prometheus.{common,local})
       (ADR 0001 / CODE_LAYER-005), shared with platform/cloud/modules/platform/main.tf.
       node-exporter stays a dev-only literal here -- main.tf never disables
       it (real clusters keep host metrics), so it isn't shared state.
       Note for whoever migrates the next Prometheus key: Helm's --set
       always outranks -f regardless of flag order, so if a key ever needs
       to move from this ~values literal into the shared JSON, the literal
       here must be deleted in the same change -- leaving both would let
       this ~values entry silently and permanently win. *)
           release
             ~label:"Prometheus"
             "prometheus"
             "prometheus-community/prometheus"
             ~namespace:"monitoring"
             ~version:"25.20.1"
               (* CODE_LAYER-008: matches platform/cloud/modules/platform/main.tf's pin *)
             ~values:[ "prometheus-node-exporter.enabled", Bool false ]
             ~values_yaml:(values_of assets "prometheus")
             ()
         ]
       else
         []
         (* FEAT-042: install ingress-nginx unconditionally, mirroring
     platform/cloud/modules/platform's helm_release.ingress_nginx (same chart version,
     pinned together) so the Ingress objects `sol up`/`sol deploy` generate are
     actually served locally instead of sitting inert. Service type NodePort
     matches base/variables.tf's documented k3d/local value of
     ingress_service_type; the controller is reached through the port-forward
     below, so no k3d host-port mapping is needed. Deliberately not a
     platform/shared/components.json entry: the platform module's own install is a
     var-driven `set` (ingress_service_type), the same category ADR 0001
     leaves inline on both sides. *))
    ; [ release
          ~label:"ingress-nginx"
          "ingress-nginx"
          "ingress-nginx/ingress-nginx"
          ~namespace:"ingress-nginx"
          ~version:"4.10.1"
          ~values:[ "controller.service.type", Str "NodePort" ]
          ()
      ]
    ]
;;

(* REFAC-139, part F: what `sol local infra up` exposes on the host -- one entry
   per port-forward, with the summary line that reports it, so the forwards
   started and the endpoints reported cannot disagree. *)
type endpoint =
  { forward : Sol_cli_port_forward.spec
  ; summary : string
  }

(* FEAT-042: the host port the local ingress-nginx controller is forwarded to.
   Deliberately not 8080 -- that is where `sol up` forwards a service, so the two
   would collide. *)
let ingress_local_port = 8088

let endpoints ~(req : Sol_cli_workspace.infra_requirements) =
  let endpoint name ~namespace ~target ~local_port ~remote_port summary =
    { forward = { Sol_cli_port_forward.name; namespace; target; local_port; remote_port }
    ; summary
    }
  in
  let grafana = needs_grafana req in
  List.concat
    [ (if req.kafka
       then
         [ (* Target the pod, not svc: the headless service only exposes the
              internal port 9093, and the external listener on 9094 is pod-only. *)
           endpoint
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
       else [])
    ; (if req.postgres
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
       else [])
    ; (if grafana
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
       else [])
    ; (if req.prometheus
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
       else [])
    ; (if req.tempo
       then
         [ (* Two forwards, matching prometheus/pushgateway's split: OTLP/HTTP
              ingestion (obs-tempo-eio's TEMPO_URL, what -svc pushes spans to)
              and the query API (what Grafana's Tempo datasource and a
              developer's own curl/Explore session read from) are different ports
              on the same Service. *)
           endpoint
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
       else [])
    ; [ (* FEAT-042: the controller install is unconditional, so is this forward
           -- a workspace Ingress can only be reached from the host through it.
           Remote port 80 is ingress-nginx's controller Service `http` port. *)
        endpoint
          "ingress"
          ~namespace:"ingress-nginx"
          ~target:"svc/ingress-nginx-controller"
          ~local_port:ingress_local_port
          ~remote_port:80
          (Printf.sprintf
             "  ingress      ✓  http://localhost:%d  (ingress-nginx, port-forwarded)"
             ingress_local_port)
      ]
    ]
;;
