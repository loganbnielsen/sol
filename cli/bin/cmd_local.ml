open Cmdliner
open Sol_cli_manifest
open Sol_cli_helm
open Result.Syntax

let check_tool name install_url =
  match Sol_cli_process.run (Sol_cli_process.cmd [ "which"; name ]) with
  | Ok _ -> Ok ()
  | Error _ ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf "%S not found in PATH.\n  Install: %s" name install_url))
;;

let require_tools () =
  let* () = check_tool "k3d" "https://k3d.io/" in
  let* () = check_tool "helm" "https://helm.sh/" in
  check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/"
;;

(* FRIC-017: k3d v5.6.0's embedded Docker client pins API 1.43, but Docker
   Engine 29 removed every API below 1.44, so any k3d invocation fails with
   "client version 1.43 is too old" on a current host. Ask the daemon for the
   oldest API it still accepts and hand that to k3d via DOCKER_API_VERSION --
   but never below k3d's own 1.43 floor, so older daemons keep working too. *)
let k3d_client_api_floor = "1.43"

let version_gt a b =
  let parts s = String.split_on_char '.' s |> List.filter_map int_of_string_opt in
  let rec cmp x y =
    match x, y with
    | [], [] -> 0
    | x :: xs, y :: ys -> if x <> y then compare x y else cmp xs ys
    | x :: _, [] -> compare x 0
    | [], y :: _ -> compare 0 y
  in
  cmp (parts a) (parts b) > 0
;;

let k3d_env () =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd
         [ "docker"; "version"; "--format"; "{{.Server.MinAPIVersion}}" ])
  with
  | Ok r ->
    let daemon_min = String.trim r.Sol_cli_process.stdout in
    if daemon_min <> "" && version_gt daemon_min k3d_client_api_floor
    then [ "DOCKER_API_VERSION", daemon_min ]
    else []
  | _ -> []
;;

let k3d args = Sol_cli_process.cmd ~env:(k3d_env ()) ("k3d" :: args)

(* ── State file ─────────────────────────────────────────────────────────── *)

let cluster_name = "sol-local"
let registry_port = 5000

(* FEAT-042: host port the local ingress-nginx controller is port-forwarded
   to. Deliberately not 8080 -- that is where `sol up` forwards a service, so
   the two would collide. Nothing else in `sol local infra up` uses 8088. *)
let ingress_local_port = 8088

(* ── Helm helpers ────────────────────────────────────────────────────────── *)

(* FRIC-006: same discard-on-failure bug as the cluster-creation/docker/
   rollout sites this ticket already fixed -- upgrade_install's captured
   result/error was being collapsed to a bare exit code at all 7 call
   sites below, each printing only a generic "X install failed" with no
   indication of why (bad values, chart not found, timeout, etc). Centralized
   here instead of fixed at each site: every helm_install caller gets the
   real diagnostic for free. *)
(* INFRA-086: what this does with a failure has changed twice now, so both
   halves are worth stating. FRIC-006's diagnostic is preserved: the component's
   own output travels with the failure instead of a bare exit code. What is new
   is *when* it runs -- each call records its install and [run_local_infra_installs]
   below installs them with bounded concurrency, because the eight releases have
   no install-time dependency on each other and installing them one after another
   was ~290s of every golden path (both languages) and of a developer's first
   `sol local infra up`.

   Deferring also means the failure is no longer immediate: the component is
   reported once the in-flight installs have been waited for, together with the
   components that never got to run, and none of it can leave a half-installed
   sibling behind with no explanation. *)
let pending_installs = ref []

let helm_install ~label release chart ~namespace ?version ?(values = []) ?values_yaml () =
  pending_installs
  := { Sol_cli_local_infra.label
     ; run =
         (fun () ->
           match
             upgrade_install ~release ~chart ~namespace ?version ~values ?values_yaml ()
           with
           | Ok _ -> Ok ()
           | Error (Sol_cli_process.Non_zero r) ->
             Error (Sol_cli_process.failure_message r)
           | Error e -> Error (Sol_cli_process.error_to_string e))
     }
     :: !pending_installs
;;

let run_local_infra_installs () =
  let installs = List.rev !pending_installs in
  pending_installs := [];
  Sol_cli_local_infra.run_bounded installs |> Sol_cli_exit.of_msg
;;

let apply_yaml yaml =
  let tmp = Sol_cli_manifest.write_tmp yaml in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove tmp with
      | _ -> ())
    (fun () ->
       Sol_cli_kubectl.apply ~ctx:Sol_cli_kube_destination.local_context ~file:tmp
       |> Result.map_error (fun e ->
         Sol_cli_exit.error ("kubectl apply failed: " ^ Sol_cli_process.error_to_string e)))
;;

let install_local_grafana_config ~dashboards ~prometheus ~tempo =
  let* () = apply_yaml dashboards in
  (* OBS-039: no longer auto-provisioned by a bundled loki-stack Grafana
     subchart -- see Sol_cli_dev_observability.loki_datasource_configmap_yaml.
     OBS-042: this datasource also carries the derivedFields link to Tempo,
     applied regardless of `tempo` -- harmless if Tempo isn't installed, and
     avoids two near-identical Loki datasource YAMLs. *)
  let* () =
    apply_yaml
      (Sol_cli_dev_observability.loki_datasource_configmap_yaml ~namespace:"monitoring")
  in
  let* () =
    if prometheus
    then
      apply_yaml
        (Sol_cli_dev_observability.prometheus_datasource_configmap_yaml
           ~namespace:"monitoring")
    else Ok ()
  in
  if tempo
  then
    apply_yaml
      (Sol_cli_dev_observability.tempo_datasource_configmap_yaml ~namespace:"monitoring")
  else Ok ()
;;

(* ── dev up ──────────────────────────────────────────────────────────────── *)

(* REFAC-115: everything `sol local infra up` reads from Sol's own assets, read
   and checked before anything is installed -- a missing or malformed asset fails
   here, not halfway through the installs. *)
type local_assets =
  { component_values : (string * string) list (** component -> merged local values *)
  ; alloy_values : string
  ; dashboards : string
  }

let local_components =
  [ "redpanda"; "postgresql"; "loki"; "grafana"; "tempo"; "prometheus" ]
;;

let read_local_assets () =
  let* assets =
    Sol_cli_platform_assets.resolve ()
    |> Result.map_error Sol_cli_platform_assets.error_to_string
  in
  let* component_values =
    local_components
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

let values_of local component = List.assoc component local.component_values

(* Sol's local cluster, created unless it already exists. *)
let provision_cluster () =
  let cluster_exists =
    Result.is_ok (Sol_cli_process.run (k3d [ "cluster"; "get"; cluster_name ]))
  in
  if cluster_exists
  then (
    Printf.printf "  cluster %s already exists, skipping\n%!" cluster_name;
    Ok ())
  else (
    (* ponytail: FRIC-008, one-time Sun->Sol migration check -- delete this
       block once nobody plausibly still has a 'sun-local' cluster around.
       A pre-rename 'sun-local' cluster's inline registry binds the same
       host port this cluster's registry needs, causing a silent k3d
       port-bind conflict with no indication of the real cause. Blocks
       unconditionally on 'sun-local' existing at all (not just on a
       verified port-5000 conflict) -- deliberately simple for a shim
       meant to be deleted, not a permanent feature worth the extra
       port-probe logic to narrow. *)
    let pre_rename_cluster_name = "sun-local" in
    let pre_rename_cluster_exists =
      Result.is_ok
        (Sol_cli_process.run (k3d [ "cluster"; "get"; pre_rename_cluster_name ]))
    in
    let* () =
      if pre_rename_cluster_exists
      then
        Error
          (Sol_cli_exit.error
             (Printf.sprintf
                "found a pre-rename '%s' k3d cluster.\n\
                \  Sol's local cluster is now named '%s', and its registry would try\n\
                \  to bind the same host port (%d) that '%s'/'sun-registry' would also \
                 use.\n\
                \  Remove the old cluster first:\n\
                \    k3d cluster delete %s\n\
                \  (rename or keep it yourself first if you still need it for something \
                 else)"
                pre_rename_cluster_name
                cluster_name
                registry_port
                pre_rename_cluster_name
                pre_rename_cluster_name))
      else Ok ()
    in
    let create_result =
      Sol_cli_process.run
        ~echo:true
        (k3d
           [ "cluster"
           ; "create"
           ; cluster_name
           ; "--registry-create"
           ; Printf.sprintf "sol-registry:%d" registry_port
           ])
    in
    (* FRIC-006: k3d's own output is the actual diagnosis (e.g. "port is already
       allocated") -- surface it instead of leaving the user to re-run k3d by hand
       to find out why. *)
    create_result
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun failure ->
      let detail =
        match failure with
        | Sol_cli_process.Non_zero r -> "\n" ^ Sol_cli_process.failure_message r
        | e -> "\n" ^ Sol_cli_process.error_to_string e
      in
      Sol_cli_exit.error ("cluster creation failed" ^ detail)))
;;

(* REFAC-107: what the workspace declares, read from sol.yml at the workspace
   root, not inferred from build files, so it is the same from any subdirectory
   and for OCaml and TypeScript units alike. *)
let declared_resources () =
  let* root =
    Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ())
    |> Sol_cli_exit.of_error Sol_cli_workspace.workspace_error_to_string
  in
  Sol_cli_config.local_infra ~root |> Sol_cli_exit.of_error Sol_cli_config.error_to_string
;;

let need_grafana (req : Sol_cli_workspace.infra_requirements) =
  req.loki || req.prometheus || req.tempo
;;

let deploy_infra ~(req : Sol_cli_workspace.infra_requirements) ~local =
  let need_any = req.kafka || req.postgres || req.loki || req.prometheus || req.tempo in
  if need_any
  then (
    ignore (Sol_cli_helm.repo_add ~name:"redpanda" ~url:"https://charts.redpanda.com");
    (* FEAT-042's chart is added here too, rather than next to its install: the
       repository is shared mutable state in helm's own config, and it must not be
       written while other installs are running. *)
    ignore
      (Sol_cli_helm.repo_add
         ~name:"ingress-nginx"
         ~url:"https://kubernetes.github.io/ingress-nginx");
    (* Alloy stays on this repo -- only loki/grafana moved (see
       grafana-community below, OBS-039). *)
    ignore
      (Sol_cli_helm.repo_add ~name:"grafana" ~url:"https://grafana.github.io/helm-charts");
    ignore
      (Sol_cli_helm.repo_add
         ~name:"grafana-community"
         ~url:"https://grafana-community.github.io/helm-charts");
    ignore
      (Sol_cli_helm.repo_add ~name:"bitnami" ~url:"https://charts.bitnami.com/bitnami");
    ignore
      (Sol_cli_helm.repo_add
         ~name:"prometheus-community"
         ~url:"https://prometheus-community.github.io/helm-charts");
    ignore (Sol_cli_helm.repo_update ()));
  if req.kafka
  then
    (* CODE_LAYER-010: values come from
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
    helm_install
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
      ~values_yaml:(values_of local "redpanda")
      ();
  if req.postgres
  then
    helm_install
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
      ~values_yaml:(values_of local "postgresql")
      ();
  if need_grafana req
  then (
    (* OBS-039: loki-stack is deprecated (no longer updated/supported per
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
    helm_install
      ~label:"Loki"
      "loki"
      "grafana-community/loki"
      ~namespace:"monitoring"
      ~version:"18.12.1"
        (* CODE_LAYER-008: matches platform/cloud/modules/platform/main.tf's pin *)
      ~values_yaml:(values_of local "loki")
      ();
    (* Values come from platform/shared/components.json (grafana.{common,local})
       (ADR 0001 / CODE_LAYER-005). sidecar.dashboards/datasources: moved
       from loki-stack's nested grafana.sidecar.* passthrough naming to this
       standalone chart's own top-level sidecar.* -- both now need an
       explicit value since this chart (unlike loki-stack) defaults
       sidecar.datasources.enabled to false. *)
    helm_install
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
      ~values_yaml:(values_of local "grafana")
      ();
    (* Cluster-wide pod stdout/stderr scraping via DaemonSet -- same role
       promtail.enabled: true played, so 'sol logs' can fall back to real
       log content even for a pod that crashed before it could push its own
       logs (OBS-004). CODE_LAYER-006: River config is rendered from
       platform/shared/observability/alloy/logs.alloy.tftpl -- the single source,
       shared with platform/cloud/modules/platform/main.tf's own templatefile() call
       for the same file -- instead of a second, hand-synced OCaml copy. *)
    helm_install
      ~label:"Alloy"
      "alloy"
      "grafana/alloy"
      ~namespace:"monitoring"
      ~version:"1.12.1"
        (* CODE_LAYER-008: matches platform/cloud/modules/platform/main.tf's pin *)
      ~values_yaml:local.alloy_values
      ());
  if req.tempo
  then
    (* OBS-042: grafana-community/tempo (not the deprecated grafana/tempo --
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
    helm_install
      ~label:"Tempo"
      "tempo"
      "grafana-community/tempo"
      ~namespace:"monitoring"
      ~version:"2.3.0"
        (* CODE_LAYER-008: matches platform/cloud/modules/platform/main.tf's pin *)
      ~values_yaml:(values_of local "tempo")
      ();
  if req.prometheus
  then
    (* prometheus-community/prometheus (not kube-prometheus-stack) — lighter weight for dev;
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
    helm_install
      ~label:"Prometheus"
      "prometheus"
      "prometheus-community/prometheus"
      ~namespace:"monitoring"
      ~version:"25.20.1"
        (* CODE_LAYER-008: matches platform/cloud/modules/platform/main.tf's pin *)
      ~values:[ "prometheus-node-exporter.enabled", Bool false ]
      ~values_yaml:(values_of local "prometheus")
      ();
  (* FEAT-042: install ingress-nginx unconditionally, mirroring
     platform/cloud/modules/platform's helm_release.ingress_nginx (same chart version,
     pinned together) so the Ingress objects `sol up`/`sol deploy` generate are
     actually served locally instead of sitting inert. Service type NodePort
     matches base/variables.tf's documented k3d/local value of
     ingress_service_type; the controller is reached through the port-forward
     below, so no k3d host-port mapping is needed. Deliberately not a
     platform/shared/components.json entry: the platform module's own install is a
     var-driven `set` (ingress_service_type), the same category ADR 0001
     leaves inline on both sides. *)
  helm_install
    ~label:"ingress-nginx"
    "ingress-nginx"
    "ingress-nginx/ingress-nginx"
    ~namespace:"ingress-nginx"
    ~version:"4.10.1"
    ~values:[ "controller.service.type", Str "NodePort" ]
    ();
  let* () = run_local_infra_installs () in
  (* Grafana's datasource ConfigMaps name the services above, so they are applied
     once those releases exist -- after the installs, not interleaved with them. *)
  if need_grafana req
  then
    install_local_grafana_config
      ~dashboards:local.dashboards
      ~prometheus:req.prometheus
      ~tempo:req.tempo
  else Ok ()
;;

let start_port_forwards ~(req : Sol_cli_workspace.infra_requirements) =
  ignore (Sys.command "sleep 2");
  (* brief pause for service endpoints to settle *)
  let pf pf_spec =
    Printf.printf
      "  port-forward  %-14s localhost:%d → %s/%s:%d\n%!"
      pf_spec.Sol_cli_port_forward.name
      pf_spec.local_port
      pf_spec.namespace
      pf_spec.target
      pf_spec.remote_port;
    Sol_cli_port_forward.start ~ctx:Sol_cli_kube_destination.local_context pf_spec
    |> Result.iter_error
         (Printf.eprintf "  warning: port-forward %s not started: %s\n%!" pf_spec.name)
  in
  if req.kafka
  then (
    (* Target the pod, not svc: the headless service only exposes the internal
       port 9093, and the external listener on 9094 is pod-only. *)
    pf
      { name = "kafka"
      ; namespace = "redpanda"
      ; target = "pod/redpanda-0"
      ; local_port = 9092
      ; remote_port = 9094
      };
    pf
      { name = "schema-registry"
      ; namespace = "redpanda"
      ; target = "svc/redpanda"
      ; local_port = 8081
      ; remote_port = 8081
      });
  if req.postgres
  then
    pf
      { name = "postgres"
      ; namespace = "postgresql"
      ; target = "svc/postgresql"
      ; local_port = 5432
      ; remote_port = 5432
      };
  if need_grafana req
  then
    pf
      { name = "loki"
      ; namespace = "monitoring"
      ; target = "svc/loki"
      ; local_port = 3100
      ; remote_port = 3100
      };
  if need_grafana req
  then
    pf
      { name = "grafana"
      ; namespace = "monitoring"
      ; target = "svc/grafana"
      ; local_port = 3000
      ; remote_port = 80
      };
  if req.prometheus
  then
    pf
      { name = "prometheus"
      ; namespace = "monitoring"
      ; target = "svc/prometheus-server"
      ; local_port = 9090
      ; remote_port = 80
      };
  if req.prometheus
  then
    pf
      { name = "pushgateway"
      ; namespace = "monitoring"
      ; target = "svc/prometheus-prometheus-pushgateway"
      ; local_port = 9091
      ; remote_port = 9091
      };
  if req.tempo
  then (
    (* Two forwards, matching prometheus/pushgateway's split above: OTLP/HTTP
       ingestion (obs-tempo-eio's TEMPO_URL, what -svc pushes spans to) and
       the query API (what Grafana's Tempo datasource and a developer's own
       curl/Explore session read from) are different ports on the same
       Service. *)
    pf
      { name = "tempo"
      ; namespace = "monitoring"
      ; target = "svc/tempo"
      ; local_port = 4318
      ; remote_port = 4318
      };
    pf
      { name = "tempo-query"
      ; namespace = "monitoring"
      ; target = "svc/tempo"
      ; local_port = 3200
      ; remote_port = 3200
      });
  (* FEAT-042: the controller install above is unconditional, so is this
     forward -- a workspace Ingress can only be reached from the host through
     it. Remote port 80 is ingress-nginx's controller Service `http` port. *)
  pf
    { name = "ingress"
    ; namespace = "ingress-nginx"
    ; target = "svc/ingress-nginx-controller"
    ; local_port = ingress_local_port
    ; remote_port = 80
    }
;;

let print_summary ~(req : Sol_cli_workspace.infra_requirements) =
  Printf.printf "\n";
  Printf.printf "  cluster      ✓  %s\n" cluster_name;
  Printf.printf "  registry     ✓  localhost:%d\n" registry_port;
  if req.kafka then Printf.printf "  kafka        ✓  localhost:9092  (port-forwarded)\n";
  if req.kafka then Printf.printf "  schema-reg   ✓  http://localhost:8081\n";
  if req.postgres
  then
    Printf.printf
      "  postgres     ✓  postgresql://postgres:dev@localhost:5432/dev  (port-forwarded)\n";
  if need_grafana req
  then Printf.printf "  loki         ✓  http://localhost:3100  (port-forwarded)\n";
  if need_grafana req
  then Printf.printf "  grafana      ✓  http://localhost:3000  (port-forwarded)\n";
  if req.prometheus
  then Printf.printf "  prometheus   ✓  http://localhost:9090  (port-forwarded)\n";
  if req.prometheus
  then Printf.printf "  pushgateway  ✓  http://localhost:9091  (port-forwarded)\n";
  if req.tempo
  then Printf.printf "  tempo        ✓  http://localhost:4318  (OTLP, port-forwarded)\n";
  if req.tempo
  then Printf.printf "  tempo-query  ✓  http://localhost:3200  (port-forwarded)\n";
  Printf.printf
    "  ingress      ✓  http://localhost:%d  (ingress-nginx, port-forwarded)\n"
    ingress_local_port;
  Printf.printf "\n"
;;

let dev_up () =
  let* () = require_tools () in
  Sol_cli_state.ensure ();
  (* Kill stale port-forwards from previous sessions, else re-running after a
     crash silently fails to bind ports while reporting success. *)
  Sol_cli_port_forward.stop_all ();
  Printf.printf "\n[1/4] Provisioning cluster...\n%!";
  let* () = provision_cluster () in
  Printf.printf "\n[2/4] Reading the workspace's declared resources...\n%!";
  let* req = declared_resources () in
  Printf.printf
    "  kafka=%-5b  postgres=%-5b  loki=%-5b  prometheus=%-5b  tempo=%b\n%!"
    req.kafka
    req.postgres
    req.loki
    req.prometheus
    req.tempo;
  let* local = read_local_assets () |> Sol_cli_exit.of_msg in
  Printf.printf "\n[3/4] Deploying infra...\n%!";
  let* () = deploy_infra ~req ~local in
  Printf.printf "\n[4/4] Starting port-forwards...\n%!";
  start_port_forwards ~req;
  print_summary ~req;
  Ok ()
;;

(* ── dev down ────────────────────────────────────────────────────────────── *)

let dev_down delete_cluster =
  let* () = check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/" in
  Printf.printf "Stopping port-forwards...\n%!";
  Sol_cli_port_forward.stop_all ();
  if delete_cluster
  then (
    let* () = check_tool "k3d" "https://k3d.io/" in
    Printf.printf "Deleting cluster %s...\n%!" cluster_name;
    ignore (Sol_cli_process.run (k3d [ "cluster"; "delete"; cluster_name ]));
    Ok ())
  else (
    Printf.printf "Port-forwards stopped. Cluster %s is still running.\n" cluster_name;
    Ok ())
;;

(* ── dev status ──────────────────────────────────────────────────────────── *)

let dev_status () =
  let* () = check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/" in
  let cluster_running =
    Result.is_ok (Sol_cli_process.run (k3d [ "cluster"; "get"; cluster_name ]))
  in
  Printf.printf
    "\nCluster:  %s  %s\n"
    cluster_name
    (if cluster_running then "✓ running" else "✗ not found");
  if cluster_running
  then (
    Printf.printf "\nPods:\n%!";
    (match
       Sol_cli_process.run (Sol_cli_process.cmd [ "kubectl"; "get"; "pods"; "-A" ])
     with
     | Ok r ->
       print_string r.Sol_cli_process.stdout;
       print_char '\n'
     | Error _ -> ());
    Printf.printf "\nPort-forwards:\n%!";
    (* REFAC-126: what Sol recorded starting, and whether each is still up. *)
    let recorded, unreadable = Sol_cli_port_forward.records () in
    (match recorded with
     | [] -> Printf.printf "  none\n"
     | recorded ->
       recorded
       |> List.iter (fun (pf : Sol_cli_port_forward.spec) ->
         Printf.printf
           "  %-12s  localhost:%d → %s/%s  %s\n"
           pf.name
           pf.local_port
           pf.namespace
           pf.target
           (if Sol_cli_port_forward.is_running pf.name then "running" else "stopped")));
    unreadable
    |> List.iter (Printf.eprintf "  warning: unreadable port-forward record: %s\n"));
  Printf.printf "\n";
  Ok ()
;;

(* ── dev run ─────────────────────────────────────────────────────────────── *)

(** Dev-local addresses matching the port-forwards from [sol local infra up], mirroring
    the cluster-internal addresses [sol up] injects but rewritten to localhost.
*)
let dev_env_vars =
  [ "KAFKA_BROKERS", "localhost:9092"
  ; "SCHEMA_REGISTRY_URL", "http://localhost:8081"
  ; "REDPANDA_ADMIN_URL", "http://localhost:9644"
  ; "POSTGRES_URL", "postgresql://postgres:dev@localhost:5432/dev"
  ; "LOKI_URL", "http://localhost:3100"
  ; "PUSHGATEWAY_URL", "http://localhost:9091"
  ; "TEMPO_URL", "http://localhost:4318"
  ; "KAFKA_SECURITY_PROTOCOL", "plaintext"
  ]
;;

(** [dev_env_vars] merged on top of the current environment, overriding any
    matching keys so every service reaches the local broker/database. *)
let build_env () =
  let current = Unix.environment () in
  let dev_keys = List.map fst dev_env_vars in
  let filtered =
    Array.to_list current
    |> List.filter (fun entry ->
      let key =
        match String.index_opt entry '=' with
        | Some i -> String.sub entry 0 i
        | None -> entry
      in
      not (List.mem key dev_keys))
  in
  let extras = List.map (fun (k, v) -> k ^ "=" ^ v) dev_env_vars in
  Array.of_list (filtered @ extras)
;;

(** Read lines from [fd] and write them to stdout, prefixed with [label].
    Returns when EOF is reached (the child process closed the pipe end). *)
let prefix_lines_thread fd label =
  let ic = Unix.in_channel_of_descr fd in
  (try
     while true do
       let line = input_line ic in
       Printf.printf "[%s] %s\n%!" label line
     done
   with
   | End_of_file | Sys_error _ -> ());
  try Unix.close fd with
  | _ -> ()
;;

type child =
  { pid : int
  ; label : string
  }

let dev_run workspace_dir scope =
  let dir =
    match workspace_dir with
    | Some d -> d
    | None -> "."
  in
  (* Change to workspace dir if given explicitly so discover_services works *)
  (match workspace_dir with
   | Some d -> Unix.chdir d
   | None -> ());
  let* inventory =
    Sol_cli_manifest.discover_services ()
    |> Sol_cli_exit.of_error Sol_cli_manifest.discover_error_to_string
  in
  let* { services; _ } =
    Sol_cli_workload_selection.resolve_nonempty
      ~none:
        "no Sol services found. Expected app/<domain>/<name>_{svc,worker,fn}/ \
         directories with a Dockerfile."
      scope
      inventory
    |> Sol_cli_exit.of_msg
  in
  Printf.printf "\n  Starting %d service(s) from %s\n" (List.length services) dir;
  services
  |> List.iter (fun svc ->
    Printf.printf
      "    [%s] %s/%s → %s/bin/main.exe\n"
      (primitive_label svc.primitive)
      svc.domain
      svc.name
      svc.dir);
  Printf.printf "\n%!";
  (* Build all services first with a single dune invocation so that parallel
     dune exec calls below don't fight over the _build/.lock file. *)
  Printf.printf "  Building...\n%!";
  let build_targets =
    List.map (fun (svc : Sol_cli_manifest.service) -> svc.dir ^ "/bin/main.exe") services
  in
  let opam_eval = "eval $(opam env 2>/dev/null) 2>/dev/null; " in
  let build_cmd =
    Printf.sprintf
      "%sdune build %s"
      opam_eval
      (String.concat " " (List.map Filename.quote build_targets))
  in
  let* () =
    match Sys.command build_cmd with
    | 0 -> Ok ()
    | rc -> Error (Sol_cli_exit.error (Printf.sprintf "dune build failed (exit %d)" rc))
  in
  Printf.printf "  Build done.\n\n%!";
  let env = build_env () in
  (* Run the pre-built executable directly, avoiding dune exec lock contention. *)
  let children =
    services
    |> List.filter_map (fun (svc : Sol_cli_manifest.service) ->
      let label = svc.domain ^ "/" ^ svc.name in
      let exe_path = "_build/default/" ^ svc.dir ^ "/bin/main.exe" in
      let cmd_str = Filename.quote exe_path in
      let pipe_read, pipe_write = Unix.pipe () in
      try
        let pid =
          Unix.create_process_env
            "sh"
            [| "sh"; "-c"; cmd_str |]
            env
            Unix.stdin
            pipe_write
            pipe_write
        in
        Unix.close pipe_write;
        let _t = Thread.create (fun () -> prefix_lines_thread pipe_read label) () in
        Some { pid; label }
      with
      | Unix.Unix_error (e, fn, _) ->
        Unix.close pipe_read;
        Unix.close pipe_write;
        Printf.eprintf
          "error: failed to spawn [%s]: %s in %s\n"
          label
          (Unix.error_message e)
          fn;
        None)
  in
  let* children =
    match children with
    | [] -> Error (Sol_cli_exit.error "no services could be started")
    | children -> Ok children
  in
  Printf.printf "  Services running — press Ctrl-C to stop all.\n\n%!";
  (* On SIGINT (Ctrl-C), kill every child before exiting *)
  let kill_all () =
    Printf.printf "\n  Stopping services...\n%!";
    children
    |> List.iter (fun c ->
      try Unix.kill c.pid Sys.sigterm with
      | _ -> ());
    (* Brief grace period, then SIGKILL *)
    Unix.sleepf 0.5;
    children
    |> List.iter (fun c ->
      try Unix.kill c.pid Sys.sigkill with
      | _ -> ())
  in
  Sys.set_signal
    Sys.sigint
    (Sys.Signal_handle
       (fun _ ->
         kill_all ();
         exit 130));
  (* Wait for children in any-exit order so an early crash is reported immediately *)
  let by_pid = Hashtbl.create 8 in
  List.iter (fun c -> Hashtbl.replace by_pid c.pid c) children;
  let remaining = ref (Hashtbl.length by_pid) in
  while !remaining > 0 do
    try
      let pid, status = Unix.wait () in
      decr remaining;
      match Hashtbl.find_opt by_pid pid with
      | None -> ()
      | Some c ->
        (match status with
         | Unix.WEXITED 0 -> ()
         | Unix.WEXITED n -> Printf.eprintf "[%s] exited with code %d\n%!" c.label n
         | Unix.WSIGNALED _ -> ()
         | Unix.WSTOPPED _ -> ())
    with
    | Unix.Unix_error _ -> remaining := 0
  done;
  Ok ()
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let up_cmd =
  Cmd.v
    (Cmd.info
       "up"
       ~doc:"Provision local k3d cluster and deploy all required infra via Helm")
    Term.(const Sol_cli_exit.exit_on $ (const dev_up $ const ()))
;;

let down_cmd =
  let cluster_flag =
    Arg.(value & flag & info [ "cluster" ] ~doc:"Also delete the k3d cluster")
  in
  Cmd.v
    (Cmd.info "down" ~doc:"Stop port-forwards (and optionally delete the cluster)")
    Term.(const Sol_cli_exit.exit_on $ (const dev_down $ cluster_flag))
;;

let status_cmd =
  Cmd.v
    (Cmd.info "status" ~doc:"Show infra pod health and registered port-forwards")
    Term.(const Sol_cli_exit.exit_on $ (const dev_status $ const ()))
;;

let run_workspace_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "workspace"; "C" ]
        ~docv:"DIR"
        ~doc:"Workspace root directory (default: current directory)")
;;

let run_scope_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "scope" ]
        ~docv:"DOMAIN[/UNIT]"
        ~doc:
          "Run one domain (`payments`) or one unit (`payments/charge_svc`). Omit to run \
           every service in the workspace.")
;;

let run_subcmd =
  Cmd.v
    (Cmd.info
       "run"
       ~doc:"Start all workspace services locally using dune exec with dev env vars")
    Term.(
      const Sol_cli_exit.exit_on $ (const dev_run $ run_workspace_arg $ run_scope_arg))
;;

(* FEAT-063: `sol local` reads as "the local destination". The substrate
   lifecycle moves under `sol local infra`, so `sol local status` can mean the
   same thing as `sol status --target <t>` (workloads) rather than overloading
   "status" with two unrelated output domains. *)
let infra_cmd =
  Cmd.group
    (Cmd.info
       "infra"
       ~doc:"Manage the local Kubernetes substrate (k3d, Redpanda, Postgres, Grafana)")
    [ up_cmd; down_cmd; status_cmd ]
;;

let cmd =
  Cmd.group
    (Cmd.info "local" ~doc:"Operate on Sol's own local cluster (k3d)")
    [ infra_cmd
    ; Cmd_status.local_cmd
    ; Cmd_logs.local_cmd
    ; Cmd_fn.local_cmd
    ; Cmd_rollback.local_cmd
    ; Cmd_migrate.local_cmd
    ; Cmd_releases.local_cmd
    ; Cmd_deployments.local_cmd
    ; run_subcmd
    ]
;;
