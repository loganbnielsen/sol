let ok = function
  | Ok x -> x
  | Error e -> Alcotest.fail e
;;

let assets () =
  match Sol_cli_platform_assets.resolve () with
  | Ok a -> a
  | Error e -> Alcotest.fail (Sol_cli_platform_assets.error_to_string e)
;;

let check_bool = Alcotest.(check bool)
let contains needle haystack = Sol_cli_string.contains ~needle haystack
let assert_contains msg s needle = check_bool msg true (contains needle s)

let test_dashboard_configmap () =
  let yaml =
    ok
      (Sol_cli_dev_observability.dashboard_configmap_yaml
         ~assets:(assets ())
         ~namespace:"monitoring")
  in
  assert_contains "kind" yaml "kind: ConfigMap";
  assert_contains "name" yaml "name: sol-grafana-dashboards";
  assert_contains "namespace" yaml "namespace: monitoring";
  assert_contains "sidecar label" yaml "grafana_dashboard: \"1\"";
  assert_contains "workspace uid" yaml "\"uid\": \"sol-workspace-overview\"";
  assert_contains "domain uid" yaml "\"uid\": \"sol-domain-overview\"";
  assert_contains "service uid" yaml "\"uid\": \"sol-service-template\"";
  assert_contains "release timeline uid" yaml "\"uid\": \"sol-release-timeline\"";
  assert_contains
    "target infrastructure uid"
    yaml
    "\"uid\": \"sol-target-infrastructure\"";
  assert_contains
    "release timeline query"
    yaml
    "{workspace=\\\"$workspace\\\", domain=\\\"$domain\\\", service=\\\"$service\\\"} | \
     logfmt | event=\\\"deploy\\\""
;;

let test_infrastructure_view_sources_are_scraped () =
  let component name =
    Sol_cli_platform_component.merged_values_yaml
      ~assets:(assets ())
      ~component:name
      ~profile:"local"
    |> ok
    |> Yojson.Safe.from_string
  in
  let member path json =
    List.fold_left (fun json key -> Yojson.Safe.Util.member key json) json path
  in
  check_bool
    "the postgres exporter is started, so the Postgres panels have a Prometheus source"
    true
    (member [ "metrics"; "enabled" ] (component "postgresql") = `Bool true);
  check_bool
    "Redpanda's pods are annotated for scraping, so the Redpanda panels have a source"
    true
    (member
       [ "statefulset"; "podTemplate"; "annotations"; "prometheus.io/scrape" ]
       (component "redpanda")
     = `String "true");
  check_bool
    "and the annotation points at Redpanda's public metrics"
    true
    (member
       [ "statefulset"; "podTemplate"; "annotations"; "prometheus.io/path" ]
       (component "redpanda")
     = `String "/public_metrics")
;;

let test_prometheus_datasource_configmap () =
  let yaml =
    Sol_cli_dev_observability.prometheus_datasource_configmap_yaml ~namespace:"monitoring"
  in
  assert_contains "name" yaml "name: grafana-prometheus-datasource";
  assert_contains "sidecar label" yaml "grafana_datasource: \"1\"";
  assert_contains "datasource" yaml "name: Prometheus";
  assert_contains
    "url"
    yaml
    "url: http://prometheus-server.monitoring.svc.cluster.local:80"
;;

let test_loki_datasource_configmap () =
  let yaml =
    Sol_cli_dev_observability.loki_datasource_configmap_yaml ~namespace:"monitoring"
  in
  assert_contains "name" yaml "name: grafana-loki-datasource";
  assert_contains "sidecar label" yaml "grafana_datasource: \"1\"";
  assert_contains "datasource" yaml "name: Loki";
  assert_contains "url" yaml "url: http://loki:3100";
  assert_contains "derivedFields datasourceUid" yaml "datasourceUid: tempo";
  assert_contains
    "derivedFields matcherRegex"
    yaml
    "matcherRegex: \"trace_id=([0-9a-f]{32})\"";
  assert_contains "derivedFields name" yaml "name: TraceID";
  assert_contains "derivedFields url" yaml "url: \"${__value.raw}\""
;;

let test_tempo_datasource_configmap () =
  let yaml =
    Sol_cli_dev_observability.tempo_datasource_configmap_yaml ~namespace:"monitoring"
  in
  assert_contains "name" yaml "name: grafana-tempo-datasource";
  assert_contains "sidecar label" yaml "grafana_datasource: \"1\"";
  assert_contains "datasource" yaml "name: Tempo";
  assert_contains "uid" yaml "uid: tempo";
  assert_contains "url" yaml "url: http://tempo:3200"
;;

let sol_home_markers =
  [ "framework/ocaml/sol-svc/lib/dune"; "framework/ocaml/kafka-eio-service/lib/dune" ]
;;

let write_file path content =
  let dir = Filename.dirname path in
  let rec mkdir_p d =
    if d = "." || d = "/" || Sys.file_exists d
    then ()
    else (
      mkdir_p (Filename.dirname d);
      try Unix.mkdir d 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mkdir_p dir;
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let fake_template =
  {tftpl|discovery.kubernetes "pods" {
  role = "pod"
}

discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets

%{ for label in taxonomy_labels ~}
  rule {
    source_labels = ["__meta_kubernetes_pod_label_${label}"]
    target_label  = "${label}"
  }
%{ endfor ~}
}

loki.write "default" {
  endpoint {
    url = "${loki_push_url}"
%{ if loki_push_basic_auth_username != "" ~}
    basic_auth {
      username = "${loki_push_basic_auth_username}"
      password = "${loki_push_basic_auth_password}"
    }
%{ endif ~}
  }
}
|tftpl}
;;

let with_fake_sol_home f =
  let root = Filename.temp_file "sol-home-test-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Fun.protect
    ~finally:(fun () ->
      let _ = Sol_cli_fs.remove_tree root in
      ())
    (fun () ->
       sol_home_markers
       |> List.iter (fun marker -> write_file (Filename.concat root marker) "");
       write_file
         (Filename.concat root "platform/shared/observability/alloy/logs.alloy.tftpl")
         fake_template;
       let prev = Sys.getenv_opt "SOL_HOME" in
       Unix.putenv "SOL_HOME" root;
       Fun.protect
         ~finally:(fun () ->
           match prev with
           | Some v -> Unix.putenv "SOL_HOME" v
           | None ->
             (try Unix.putenv "SOL_HOME" "" with
              | _ -> ()))
         (fun () -> f root))
;;

let test_alloy_render_expands_taxonomy_loop () =
  with_fake_sol_home (fun _sol_home ->
    let river =
      ok
      @@ Sol_cli_dev_observability.render_alloy_config
           ~assets:(assets ())
           ~taxonomy_labels:[ "workspace"; "domain"; "service" ]
           ~loki_push_url:"http://loki:3100/loki/api/v1/push"
           ~loki_push_basic_auth_username:""
           ~loki_push_basic_auth_password:""
    in
    assert_contains "workspace rule" river "__meta_kubernetes_pod_label_workspace";
    assert_contains "domain rule" river "__meta_kubernetes_pod_label_domain";
    assert_contains "service rule" river "__meta_kubernetes_pod_label_service";
    check_bool
      "primitive rule absent"
      false
      (contains "__meta_kubernetes_pod_label_primitive" river))
;;

let test_alloy_render_omits_basic_auth_when_empty () =
  with_fake_sol_home (fun _sol_home ->
    let river =
      ok
      @@ Sol_cli_dev_observability.render_alloy_config
           ~assets:(assets ())
           ~taxonomy_labels:[ "workspace" ]
           ~loki_push_url:"http://loki:3100/loki/api/v1/push"
           ~loki_push_basic_auth_username:""
           ~loki_push_basic_auth_password:""
    in
    check_bool "no basic_auth block" false (contains "basic_auth" river);
    assert_contains "push url present" river "http://loki:3100/loki/api/v1/push")
;;

let test_alloy_render_includes_basic_auth_when_set () =
  with_fake_sol_home (fun _sol_home ->
    let river =
      ok
      @@ Sol_cli_dev_observability.render_alloy_config
           ~assets:(assets ())
           ~taxonomy_labels:[ "workspace" ]
           ~loki_push_url:"https://loki.example.com/loki/api/v1/push"
           ~loki_push_basic_auth_username:"promtail"
           ~loki_push_basic_auth_password:"secret"
    in
    assert_contains "basic_auth block" river "basic_auth {";
    assert_contains "username" river "username = \"promtail\"";
    assert_contains "password" river "password = \"secret\"")
;;

let test_alloy_values_yaml_against_real_file () =
  match Sol_cli_platform_assets.resolve () with
  | Error e -> Alcotest.fail (Sol_cli_platform_assets.error_to_string e)
  | Ok _ ->
    let yaml = ok (Sol_cli_dev_observability.alloy_values_yaml ~assets:(assets ())) in
    assert_contains "helm values shape" yaml "configMap:";
    assert_contains "pod discovery" yaml "discovery.kubernetes \"pods\"";
    assert_contains "kubernetes API tailing" yaml "loki.source.kubernetes \"pods\"";
    assert_contains "write component" yaml "loki.write \"default\"";
    assert_contains "push url" yaml "http://loki:3100/loki/api/v1/push";
    assert_contains
      "taxonomy label: workspace"
      yaml
      "__meta_kubernetes_pod_label_workspace";
    assert_contains "taxonomy label: release" yaml "__meta_kubernetes_pod_label_release";
    check_bool
      "no basic_auth block for sol local infra up"
      false
      (contains "basic_auth" yaml)
;;

let test_alloy_values_yaml_carries_the_config_exactly () =
  let a = assets () in
  let yaml = ok (Sol_cli_dev_observability.alloy_values_yaml ~assets:a) in
  let config =
    ok
      (Sol_cli_dev_observability.render_alloy_config
         ~assets:a
         ~taxonomy_labels:[ "workspace"; "domain"; "service"; "primitive"; "release" ]
         ~loki_push_url:"http://loki:3100/loki/api/v1/push"
         ~loki_push_basic_auth_username:""
         ~loki_push_basic_auth_password:"")
  in
  match Yaml.of_string yaml with
  | Ok (`O [ ("alloy", `O [ ("configMap", `O [ ("content", `String content) ]) ]) ]) ->
    Alcotest.(check string) "content is the rendered config" config content
  | Ok _ -> Alcotest.failf "unexpected values shape:\n%s" yaml
  | Error (`Msg m) -> Alcotest.failf "values file does not parse: %s\n%s" m yaml
;;

let%test "grafana: dashboard configmap" = test_dashboard_configmap ()

let%test "grafana: prometheus datasource configmap" =
  test_prometheus_datasource_configmap ()
;;

let%test "grafana: loki datasource configmap" = test_loki_datasource_configmap ()
let%test "grafana: tempo datasource configmap" = test_tempo_datasource_configmap ()

let%test "grafana: the infrastructure view's sources are scraped" =
  test_infrastructure_view_sources_are_scraped ()
;;

let%test "alloy: render expands taxonomy loop" =
  test_alloy_render_expands_taxonomy_loop ()
;;

let%test "alloy: render omits empty basic_auth" =
  test_alloy_render_omits_basic_auth_when_empty ()
;;

let%test "alloy: render includes set basic_auth" =
  test_alloy_render_includes_basic_auth_when_set ()
;;

let%test "alloy: values yaml (real file)" = test_alloy_values_yaml_against_real_file ()

let%test "alloy: values yaml carries the config exactly" =
  test_alloy_values_yaml_carries_the_config_exactly ()
;;
