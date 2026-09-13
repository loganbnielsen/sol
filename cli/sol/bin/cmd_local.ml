open Cmdliner
open Sol_cli_manifest
open Sol_cli_helm

let check_tool name install_url =
  match Sol_cli_process.run (Sol_cli_process.cmd [ "which"; name ]) with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> ()
  | _ ->
    Printf.eprintf "error: %S not found in PATH.\n" name;
    Printf.eprintf "  Install: %s\n" install_url;
    exit 1
;;

let require_tools () =
  check_tool "k3d" "https://k3d.io/";
  check_tool "helm" "https://helm.sh/";
  check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/"
;;

(* ── State file ─────────────────────────────────────────────────────────── *)

let cluster_name = "sol-local"
let registry_port = 5000

(* FEAT-042: host port the local ingress-nginx controller is port-forwarded
   to. Deliberately not 8080 -- that is where `sol up` forwards a service, so
   the two would collide. Nothing else in `sol dev up` uses 8088. *)
let ingress_local_port = 8088

(* ── Helm helpers ────────────────────────────────────────────────────────── *)

(* FRIC-006: same discard-on-failure bug as the cluster-creation/docker/
   rollout sites this ticket already fixed -- upgrade_install's captured
   result/error was being collapsed to a bare exit code at all 7 call
   sites below, each printing only a generic "X install failed" with no
   indication of why (bad values, chart not found, timeout, etc). Centralized
   here instead of fixed at each site: every helm_install caller gets the
   real diagnostic for free. *)
let helm_install ~label release chart ~namespace ?version ?(values = []) ?values_yaml () =
  match upgrade_install ~release ~chart ~namespace ?version ~values ?values_yaml () with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> ()
  | Ok r ->
    Printf.eprintf "error: %s install failed\n" label;
    if r.Sol_cli_process.stderr <> ""
    then Printf.eprintf "%s\n" r.Sol_cli_process.stderr
    else if r.Sol_cli_process.stdout <> ""
    then Printf.eprintf "%s\n" r.Sol_cli_process.stdout;
    exit 1
  | Error e ->
    Printf.eprintf "error: %s install failed\n" label;
    Printf.eprintf "%s\n" (Sol_cli_process.error_to_string e);
    exit 1
;;

let apply_yaml yaml =
  let tmp = Sol_cli_manifest.write_tmp yaml in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove tmp with
      | _ -> ())
    (fun () ->
       match Sol_cli_kubectl.apply ~file:tmp with
       | Ok () -> ()
       | Error e ->
         Printf.eprintf
           "error: kubectl apply failed: %s\n"
           (Sol_cli_process.error_to_string e);
         exit 1)
;;

let install_local_grafana_config ~prometheus ~tempo =
  apply_yaml (Sol_cli_dev_observability.dashboard_configmap_yaml ~namespace:"monitoring");
  (* OBS-039: no longer auto-provisioned by a bundled loki-stack Grafana
     subchart -- see Sol_cli_dev_observability.loki_datasource_configmap_yaml.
     OBS-042: this datasource also carries the derivedFields link to Tempo,
     applied regardless of `tempo` -- harmless if Tempo isn't installed, and
     avoids two near-identical Loki datasource YAMLs. *)
  apply_yaml
    (Sol_cli_dev_observability.loki_datasource_configmap_yaml ~namespace:"monitoring");
  if prometheus
  then
    apply_yaml
      (Sol_cli_dev_observability.prometheus_datasource_configmap_yaml
         ~namespace:"monitoring");
  if tempo
  then
    apply_yaml
      (Sol_cli_dev_observability.tempo_datasource_configmap_yaml ~namespace:"monitoring")
;;

(* ── dev up ──────────────────────────────────────────────────────────────── *)

let dev_up () =
  require_tools ();
  Sol_cli_state.ensure ();
  (* Kill stale port-forwards from previous sessions, else re-running after a
     crash silently fails to bind ports while reporting success. *)
  Sol_cli_port_forward.stop_all ();
  (* 1. Cluster *)
  Printf.printf "\n[1/4] Provisioning cluster...\n%!";
  let cluster_exists =
    match
      Sol_cli_process.run (Sol_cli_process.cmd [ "k3d"; "cluster"; "get"; cluster_name ])
    with
    | Ok r -> r.Sol_cli_process.exit_code = 0
    | Error _ -> false
  in
  if cluster_exists
  then Printf.printf "  cluster %s already exists, skipping\n%!" cluster_name
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
      match
        Sol_cli_process.run
          (Sol_cli_process.cmd [ "k3d"; "cluster"; "get"; pre_rename_cluster_name ])
      with
      | Ok r -> r.Sol_cli_process.exit_code = 0
      | Error _ -> false
    in
    if pre_rename_cluster_exists
    then (
      Printf.eprintf
        "error: found a pre-rename '%s' k3d cluster.\n"
        pre_rename_cluster_name;
      Printf.eprintf
        "  Sol's local cluster is now named '%s', and its registry would try\n"
        cluster_name;
      Printf.eprintf
        "  to bind the same host port (%d) that '%s'/'sun-registry' would also use.\n"
        registry_port
        pre_rename_cluster_name;
      Printf.eprintf "  Remove the old cluster first:\n";
      Printf.eprintf "    k3d cluster delete %s\n" pre_rename_cluster_name;
      Printf.eprintf
        "  (rename or keep it yourself first if you still need it for something else)\n";
      exit 1);
    let create_result =
      Sol_cli_process.run
        ~echo:true
        (Sol_cli_process.cmd
           [ "k3d"
           ; "cluster"
           ; "create"
           ; cluster_name
           ; "--registry-create"
           ; Printf.sprintf "sol-registry:%d" registry_port
           ])
    in
    let rc =
      match create_result with
      | Ok r -> r.Sol_cli_process.exit_code
      | Error _ -> 1
    in
    if rc <> 0
    then (
      Printf.eprintf "error: cluster creation failed\n";
      (* FRIC-006: k3d's own stderr is the actual diagnosis (e.g. "port is
         already allocated") -- surface it instead of leaving the user to
         re-run k3d by hand to find out why. *)
      (match create_result with
       | Ok r when r.Sol_cli_process.stderr <> "" ->
         Printf.eprintf "%s\n" r.Sol_cli_process.stderr
       | Ok r when r.Sol_cli_process.stdout <> "" ->
         Printf.eprintf "%s\n" r.Sol_cli_process.stdout
       | Ok _ -> ()
       | Error e -> Printf.eprintf "%s\n" (Sol_cli_process.error_to_string e));
      exit 1));
  (* 2. Scan *)
  Printf.printf "\n[2/4] Scanning workspace...\n%!";
  let req = Sol_cli_workspace.scan ~dir:"." in
  Printf.printf
    "  kafka=%-5b  postgres=%-5b  loki=%-5b  prometheus=%-5b  tempo=%b\n%!"
    req.kafka
    req.postgres
    req.loki
    req.prometheus
    req.tempo;
  (* 3. Infra *)
  Printf.printf "\n[3/4] Deploying infra...\n%!";
  let need_any = req.kafka || req.postgres || req.loki || req.prometheus || req.tempo in
  if need_any
  then (
    ignore (Sol_cli_helm.repo_add ~name:"redpanda" ~url:"https://charts.redpanda.com");
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
  then (
    Printf.printf "\n  Installing Redpanda...\n%!";
    (* CODE_LAYER-010: values come from
       cli/platform/components/redpanda/{values-common,values-local}.json
       (ADR 0001), shared with cli/platform/infra/base/main.tf --
       tls.enabled/config.cluster.auto_create_topics_enabled
       (values-common.json) and statefulset.replicas/resources.cpu.cores
       (values-local.json, for cmd_local.ml's benefit only -- main.tf's own
       var-driven override in its trailing values-list entry always wins
       there, same shadowing pattern as Loki's persistence knob).

       storage.persistentVolume.size and the external.*/listeners.kafka.*
       block stay inline OCaml literals, NOT in the shared JSON: adversarial
       review on this ticket caught that main.tf's own override block
       doesn't touch either, so putting them in values-local.json would
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
         resolves and a fresh `sol local up` could not install a substrate at
         all. That removed the option FRIC-010 preserved, so the pin moves to
         26.1.11 (image v26.1.17): FRIC-010's evaluated target, one minor behind
         newest, within support, and confirmed to render cleanly against
         values-common.json/values-local.json (the console.* schema workaround
         is still required upstream). A cluster still on v24.2.7 must be
         recreated rather than upgraded in place -- see INFRA-013.
         CODE_LAYER-008: matches cli/platform/infra/base/main.tf's pin. *)
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
      ~values_yaml:
        (Sol_cli_platform_component.merged_values_yaml
           ~component:"redpanda"
           ~profile:"local")
      ());
  if req.postgres
  then (
    Printf.printf "\n  Installing PostgreSQL...\n%!";
    helm_install
      ~label:"PostgreSQL"
      "postgresql"
      "bitnami/postgresql"
      ~namespace:"postgresql"
        (* CODE_LAYER-008: matches cli/platform/infra/base/main.tf's pin. Not
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
         cli/platform/components/postgresql/{values-common,values-local}.json
         (ADR 0001) -- auth.database ("dev") is genuinely shared with
         cli/platform/infra/base/main.tf; auth.postgresPassword and
         primary.persistence.enabled are dev-only local-profile content
         (main.tf keeps its own var-driven `set` for both -- a real secret
         and an "ephemeral by default" choice matching Loki/Prometheus's
         local profile, neither with a value cmd_local.ml should share). *)
      ~values_yaml:
        (Sol_cli_platform_component.merged_values_yaml
           ~component:"postgresql"
           ~profile:"local")
      ());
  let need_grafana = req.loki || req.prometheus || req.tempo in
  if need_grafana
  then (
    (* OBS-039: loki-stack is deprecated (no longer updated/supported per
       Grafana Labs' own chart README) and its bundled Promtail reached
       end-of-life March 2026. Split into the same three charts
       cli/platform/infra/base/main.tf uses in production ("Dev mirrors prod
       exactly") -- loki (community-maintained), grafana (standalone), and
       alloy (Promtail's official successor, log-shipping role only). *)
    Printf.printf "\n  Installing Loki...\n%!";
    (* Values come from cli/platform/components/loki/{values-common,values-local}.json
       (ADR 0001 / CODE_LAYER-005) -- the same "local" profile
       cli/platform/infra/base/main.tf uses for its own non-durable
       observability_backend branch, so a fix like BUG-013's
       replication_factor lands here automatically instead of requiring a
       second, independently-maintained edit (BUG-016). *)
    helm_install
      ~label:"Loki"
      "loki"
      "grafana-community/loki"
      ~namespace:"monitoring"
      ~version:"18.12.1"
        (* CODE_LAYER-008: matches cli/platform/infra/base/main.tf's pin *)
      ~values_yaml:
        (Sol_cli_platform_component.merged_values_yaml ~component:"loki" ~profile:"local")
      ();
    Printf.printf "\n  Installing Grafana...\n%!";
    (* Values come from cli/platform/components/grafana/{values-common,values-local}.json
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
        (* CODE_LAYER-008: matches cli/platform/infra/base/main.tf's pin *)
        (* CODE_LAYER-008: base/main.tf sets adminPassword explicitly
         (var.grafana_admin_password); left at the chart's own default here
         previously, making sol dev up's Grafana login undocumented and
         chart-version-dependent. Fixed dev-only value, matching
         PostgreSQL's hardcoded "dev" password convention above. *)
      ~values:[ "adminPassword", Str "dev" ]
      ~values_yaml:
        (Sol_cli_platform_component.merged_values_yaml
           ~component:"grafana"
           ~profile:"local")
      ();
    Printf.printf "\n  Installing Alloy...\n%!";
    (* Cluster-wide pod stdout/stderr scraping via DaemonSet -- same role
       promtail.enabled: true played, so 'sol logs' can fall back to real
       log content even for a pod that crashed before it could push its own
       logs (OBS-004). CODE_LAYER-006: River config is rendered from
       cli/platform/infra/base/alloy/logs.alloy.tftpl -- the single source,
       shared with cli/platform/infra/base/main.tf's own templatefile() call
       for the same file -- instead of a second, hand-synced OCaml copy. *)
    helm_install
      ~label:"Alloy"
      "alloy"
      "grafana/alloy"
      ~namespace:"monitoring"
      ~version:"1.12.1"
        (* CODE_LAYER-008: matches cli/platform/infra/base/main.tf's pin *)
      ~values_yaml:(Sol_cli_dev_observability.alloy_values_yaml ())
      ());
  if req.tempo
  then (
    Printf.printf "\n  Installing Tempo...\n%!";
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
    (* cli/platform/components/tempo/ has nothing to say today (both paths
       already agree by relying on the chart's own defaults) -- wiring it up
       anyway locks in the source of truth so the CI guardrail can catch the
       next Tempo value that would otherwise drift, see ADR 0001. *)
    helm_install
      ~label:"Tempo"
      "tempo"
      "grafana-community/tempo"
      ~namespace:"monitoring"
      ~version:"2.3.0" (* CODE_LAYER-008: matches cli/platform/infra/base/main.tf's pin *)
      ~values_yaml:
        (Sol_cli_platform_component.merged_values_yaml
           ~component:"tempo"
           ~profile:"local")
      ());
  if req.prometheus
  then (
    Printf.printf "\n  Installing Prometheus...\n%!";
    (* prometheus-community/prometheus (not kube-prometheus-stack) — lighter weight for dev;
       includes server, alertmanager, pushgateway, kube-state-metrics, node-exporter.
       server.persistentVolume/pushgateway/alertmanager come from
       cli/platform/components/prometheus/{values-common,values-local}.json
       (ADR 0001 / CODE_LAYER-005), shared with cli/platform/infra/base/main.tf.
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
        (* CODE_LAYER-008: matches cli/platform/infra/base/main.tf's pin *)
      ~values:[ "prometheus-node-exporter.enabled", Bool false ]
      ~values_yaml:
        (Sol_cli_platform_component.merged_values_yaml
           ~component:"prometheus"
           ~profile:"local")
      ());
  if need_grafana
  then install_local_grafana_config ~prometheus:req.prometheus ~tempo:req.tempo;
  (* FEAT-042: install ingress-nginx unconditionally, mirroring
     cli/platform/infra/base's helm_release.ingress_nginx (same chart version,
     pinned together) so the Ingress objects `sol up`/`sol deploy` generate are
     actually served locally instead of sitting inert. Service type NodePort
     matches base/variables.tf's documented k3d/local value of
     ingress_service_type; the controller is reached through the port-forward
     below, so no k3d host-port mapping is needed. Deliberately not a
     cli/platform/components/ entry: base/main.tf's own install is a
     var-driven `set` (ingress_service_type), the same category ADR 0001
     leaves inline on both sides. *)
  Printf.printf "\n  Installing ingress-nginx...\n%!";
  ignore
    (Sol_cli_helm.repo_add
       ~name:"ingress-nginx"
       ~url:"https://kubernetes.github.io/ingress-nginx");
  ignore (Sol_cli_helm.repo_update ());
  helm_install
    ~label:"ingress-nginx"
    "ingress-nginx"
    "ingress-nginx/ingress-nginx"
    ~namespace:"ingress-nginx"
    ~version:"4.10.1"
    ~values:[ "controller.service.type", Str "NodePort" ]
    ();
  (* 4. Port-forwards *)
  Printf.printf "\n[4/4] Starting port-forwards...\n%!";
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
    Sol_cli_port_forward.start pf_spec
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
  if need_grafana
  then
    pf
      { name = "loki"
      ; namespace = "monitoring"
      ; target = "svc/loki"
      ; local_port = 3100
      ; remote_port = 3100
      };
  if need_grafana
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
    };
  (* Summary *)
  Printf.printf "\n";
  Printf.printf "  cluster      ✓  %s\n" cluster_name;
  Printf.printf "  registry     ✓  localhost:%d\n" registry_port;
  if req.kafka then Printf.printf "  kafka        ✓  localhost:9092  (port-forwarded)\n";
  if req.kafka then Printf.printf "  schema-reg   ✓  http://localhost:8081\n";
  if req.postgres
  then
    Printf.printf
      "  postgres     ✓  postgresql://postgres:dev@localhost:5432/dev  (port-forwarded)\n";
  if need_grafana
  then Printf.printf "  loki         ✓  http://localhost:3100  (port-forwarded)\n";
  if need_grafana
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

(* ── dev down ────────────────────────────────────────────────────────────── *)

let dev_down delete_cluster =
  check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/";
  Printf.printf "Stopping port-forwards...\n%!";
  Sol_cli_port_forward.stop_all ();
  if delete_cluster
  then (
    check_tool "k3d" "https://k3d.io/";
    Printf.printf "Deleting cluster %s...\n%!" cluster_name;
    ignore
      (Sol_cli_process.run
         (Sol_cli_process.cmd [ "k3d"; "cluster"; "delete"; cluster_name ])))
  else Printf.printf "Port-forwards stopped. Cluster %s is still running.\n" cluster_name
;;

(* ── dev status ──────────────────────────────────────────────────────────── *)

let dev_status () =
  check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/";
  let cluster_running =
    match
      Sol_cli_process.run (Sol_cli_process.cmd [ "k3d"; "cluster"; "get"; cluster_name ])
    with
    | Ok r -> r.Sol_cli_process.exit_code = 0
    | Error _ -> false
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
    if Sys.file_exists Sol_cli_state.dir
    then (
      let entries =
        try Sys.readdir Sol_cli_state.dir with
        | _ -> [||]
      in
      let pids =
        Array.to_list entries |> List.filter (fun f -> Filename.check_suffix f ".pid")
      in
      if pids = []
      then Printf.printf "  none\n"
      else
        List.iter
          (fun f ->
             let name = Filename.chop_suffix f ".pid" in
             let path = Printf.sprintf "%s/%s" Sol_cli_state.dir f in
             let pid_s =
               try
                 let ic = open_in path in
                 let s = String.trim (In_channel.input_all ic) in
                 close_in ic;
                 s
               with
               | _ -> "?"
             in
             Printf.printf "  %-12s  pid %s\n" name pid_s)
          pids));
  Printf.printf "\n"
;;

(* ── dev run ─────────────────────────────────────────────────────────────── *)

(** Dev-local addresses matching the port-forwards from [sol dev up], mirroring
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
  ; "KAFKA_SECURITY_PROTOCOL", "Plaintext"
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
  let services =
    match Sol_cli_workload_selection.resolve scope (discover_services ()) with
    | Ok selected -> selected.Sol_cli_workload_selection.services
    | Error message ->
      Printf.eprintf "error: %s\n" message;
      exit 1
  in
  if services = []
  then (
    Printf.eprintf "error: no Sol services found. ";
    Printf.eprintf
      "Expected app/<domain>/<name>_{svc,worker,fn}/ directories with a Dockerfile.\n";
    exit 1);
  Printf.printf "\n  Starting %d service(s) from %s\n" (List.length services) dir;
  List.iter
    (fun svc ->
       Printf.printf
         "    [%s] %s/%s → %s/bin/main.exe\n"
         (primitive_label svc.primitive)
         svc.domain
         svc.name
         svc.dir)
    services;
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
  let build_rc = Sys.command build_cmd in
  if build_rc <> 0
  then (
    Printf.eprintf "error: dune build failed (exit %d)\n" build_rc;
    exit 1);
  Printf.printf "  Build done.\n\n%!";
  let env = build_env () in
  (* Run the pre-built executable directly, avoiding dune exec lock contention. *)
  let children =
    List.filter_map
      (fun (svc : Sol_cli_manifest.service) ->
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
      services
  in
  if children = []
  then (
    Printf.eprintf "error: no services could be started\n";
    exit 1);
  Printf.printf "  Services running — press Ctrl-C to stop all.\n\n%!";
  (* On SIGINT (Ctrl-C), kill every child before exiting *)
  let kill_all () =
    Printf.printf "\n  Stopping services...\n%!";
    List.iter
      (fun c ->
         try Unix.kill c.pid Sys.sigterm with
         | _ -> ())
      children;
    (* Brief grace period, then SIGKILL *)
    Unix.sleepf 0.5;
    List.iter
      (fun c ->
         try Unix.kill c.pid Sys.sigkill with
         | _ -> ())
      children
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
  done
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let up_cmd =
  Cmd.v
    (Cmd.info
       "up"
       ~doc:"Provision local k3d cluster and deploy all required infra via Helm")
    Term.(const dev_up $ const ())
;;

let down_cmd =
  let cluster_flag =
    Arg.(value & flag & info [ "cluster" ] ~doc:"Also delete the k3d cluster")
  in
  Cmd.v
    (Cmd.info "down" ~doc:"Stop port-forwards (and optionally delete the cluster)")
    Term.(const dev_down $ cluster_flag)
;;

let status_cmd =
  Cmd.v
    (Cmd.info "status" ~doc:"Show infra pod health and registered port-forwards")
    Term.(const dev_status $ const ())
;;

let run_workspace_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "workspace"; "C" ]
        ~docv:"DIR"
        ~doc:"Workspace root directory (default: current directory)")
;;

let run_scope_arg =
  Arg.(
    value
    & opt (some string) None
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
    Term.(const dev_run $ run_workspace_arg $ run_scope_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info "local" ~doc:"Manage the local cluster (k3d) and its substrate")
    [ up_cmd; down_cmd; status_cmd; run_subcmd ]
;;
