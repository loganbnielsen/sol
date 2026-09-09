let check_bool = Alcotest.(check bool)

let contains needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let assert_contains msg s needle = check_bool msg true (contains needle s)

(* CODE_LAYER-007: dashboard_configmap_yaml reads the real
   cli/platform/infra/base/dashboards/*.json files (via the same SOL_HOME
   ancestor-walk resolution proven out for render_alloy_config), the same
   files cli/platform/infra/base/main.tf's kubernetes_config_map.grafana_dashboards
   loads via file(...) -- not a fixture, so this exercises production
   content end to end. *)
let test_dashboard_configmap () =
  let yaml =
    Sol_cli_dev_observability.dashboard_configmap_yaml ~namespace:"monitoring"
  in
  assert_contains "kind" yaml "kind: ConfigMap";
  assert_contains "name" yaml "name: sol-grafana-dashboards";
  assert_contains "namespace" yaml "namespace: monitoring";
  assert_contains "sidecar label" yaml "grafana_dashboard: \"1\"";
  assert_contains "workspace uid" yaml "\"uid\": \"sol-workspace-overview\"";
  assert_contains "domain uid" yaml "\"uid\": \"sol-domain-overview\"";
  assert_contains "service uid" yaml "\"uid\": \"sol-service-template\"";
  assert_contains "release timeline uid" yaml
    "\"uid\": \"sol-release-timeline\"";
  assert_contains "release timeline query" yaml
    "{workspace=\\\"$workspace\\\", domain=\\\"$domain\\\", \
     service=\\\"$service\\\"} | logfmt | event=\\\"deploy\\\""

let test_prometheus_datasource_configmap () =
  let yaml =
    Sol_cli_dev_observability.prometheus_datasource_configmap_yaml
      ~namespace:"monitoring"
  in
  assert_contains "name" yaml "name: grafana-prometheus-datasource";
  assert_contains "sidecar label" yaml "grafana_datasource: \"1\"";
  assert_contains "datasource" yaml "name: Prometheus";
  assert_contains "url" yaml
    "url: http://prometheus-server.monitoring.svc.cluster.local:80"

(* OBS-039: no longer auto-provisioned by a bundled loki-stack Grafana
   subchart -- see sol_cli_dev_observability.ml's comment on
   loki_datasource_configmap_yaml. Every dashboard above references a
   datasource named exactly "Loki", so a missing/misnamed datasource here
   silently breaks every Loki panel.
   OBS-042: also asserts the derivedFields link to Tempo -- a trace_id in a
   Loki log line must be clickable through to its Tempo waterfall. *)
let test_loki_datasource_configmap () =
  let yaml =
    Sol_cli_dev_observability.loki_datasource_configmap_yaml
      ~namespace:"monitoring"
  in
  assert_contains "name" yaml "name: grafana-loki-datasource";
  assert_contains "sidecar label" yaml "grafana_datasource: \"1\"";
  assert_contains "datasource" yaml "name: Loki";
  assert_contains "url" yaml "url: http://loki:3100";
  assert_contains "derivedFields datasourceUid" yaml "datasourceUid: tempo";
  assert_contains "derivedFields matcherRegex" yaml
    "matcherRegex: \"trace_id=([0-9a-f]{32})\"";
  assert_contains "derivedFields name" yaml "name: TraceID";
  assert_contains "derivedFields url" yaml "url: \"${__value.raw}\""

(* OBS-042: Tempo query API (port 3200, distinct from the OTLP/HTTP
   ingestion port 4318 obs-tempo-eio's -svc backend pushes spans to)
   exposed as a Grafana datasource, mirroring Loki/Prometheus above. uid is
   pinned so the Loki datasource's derivedFields entry above can reference
   it by a stable value. *)
let test_tempo_datasource_configmap () =
  let yaml =
    Sol_cli_dev_observability.tempo_datasource_configmap_yaml
      ~namespace:"monitoring"
  in
  assert_contains "name" yaml "name: grafana-tempo-datasource";
  assert_contains "sidecar label" yaml "grafana_datasource: \"1\"";
  assert_contains "datasource" yaml "name: Tempo";
  assert_contains "uid" yaml "uid: tempo";
  assert_contains "url" yaml "url: http://tempo:3200"

(* CODE_LAYER-006: render_alloy_config is a hermetic templater over
   cli/platform/infra/base/alloy/logs.alloy.tftpl (${var}/for/if substitution)
   -- exercised here against a synthetic fixture, not the real file, so
   this test doesn't depend on the .tftpl being reachable inside dune's
   build sandbox (it isn't -- only directories a dune stanza references
   get copied into _build/default, and platform/ has none). Builds a
   throwaway "Sol home" containing just the two marker files
   Sol_cli_cmd_new.is_sol_home checks for plus the synthetic template,
   same pattern as test_platform_component.ml's with_fake_sol_home. *)
let sol_home_markers =
  [ "framework/sol-svc/lib/dune"; "framework/kafka-eio-service/lib/dune" ]

let write_file path content =
  let dir = Filename.dirname path in
  let rec mkdir_p d =
    if d = "." || d = "/" || Sys.file_exists d then ()
    else (
      mkdir_p (Filename.dirname d);
      try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mkdir_p dir;
  let oc = open_out path in
  output_string oc content;
  close_out oc

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

let with_fake_sol_home f =
  let root = Filename.temp_file "sol-home-test-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Fun.protect
    ~finally:(fun () ->
      let _ = Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)) in
      ())
    (fun () ->
      List.iter
        (fun marker -> write_file (Filename.concat root marker) "")
        sol_home_markers;
      write_file
        (Filename.concat root "cli/platform/infra/base/alloy/logs.alloy.tftpl")
        fake_template;
      let prev = Sys.getenv_opt "SOL_HOME" in
      Unix.putenv "SOL_HOME" root;
      Fun.protect
        ~finally:(fun () ->
          match prev with
          | Some v -> Unix.putenv "SOL_HOME" v
          | None -> ( try Unix.putenv "SOL_HOME" "" with _ -> ()))
        (fun () -> f root))

let test_alloy_render_expands_taxonomy_loop () =
  with_fake_sol_home (fun sol_home ->
      let river =
        Sol_cli_dev_observability.render_alloy_config ~sol_home
          ~taxonomy_labels:[ "workspace"; "domain"; "service" ]
          ~loki_push_url:"http://loki:3100/loki/api/v1/push"
          ~loki_push_basic_auth_username:"" ~loki_push_basic_auth_password:""
      in
      assert_contains "workspace rule" river
        "__meta_kubernetes_pod_label_workspace";
      assert_contains "domain rule" river "__meta_kubernetes_pod_label_domain";
      assert_contains "service rule" river "__meta_kubernetes_pod_label_service";
      (* Not present in the fixture's taxonomy_labels arg -- proves the loop
       renders exactly the given list, not a hardcoded fallback. *)
      check_bool "primitive rule absent" false
        (contains "__meta_kubernetes_pod_label_primitive" river))

let test_alloy_render_omits_basic_auth_when_empty () =
  with_fake_sol_home (fun sol_home ->
      let river =
        Sol_cli_dev_observability.render_alloy_config ~sol_home
          ~taxonomy_labels:[ "workspace" ]
          ~loki_push_url:"http://loki:3100/loki/api/v1/push"
          ~loki_push_basic_auth_username:"" ~loki_push_basic_auth_password:""
      in
      check_bool "no basic_auth block" false (contains "basic_auth" river);
      assert_contains "push url present" river
        "http://loki:3100/loki/api/v1/push")

let test_alloy_render_includes_basic_auth_when_set () =
  with_fake_sol_home (fun sol_home ->
      let river =
        Sol_cli_dev_observability.render_alloy_config ~sol_home
          ~taxonomy_labels:[ "workspace" ]
          ~loki_push_url:"https://loki.example.com/loki/api/v1/push"
          ~loki_push_basic_auth_username:"promtail"
          ~loki_push_basic_auth_password:"secret"
      in
      assert_contains "basic_auth block" river "basic_auth {";
      assert_contains "username" river "username = \"promtail\"";
      assert_contains "password" river "password = \"secret\"")

(* OBS-039: `sol dev up`'s own local-profile call -- reads the real
   cli/platform/infra/base/alloy/logs.alloy.tftpl (CODE_LAYER-006: the same
   file cli/platform/infra/base/main.tf's helm_release.alloy renders from).
   Sol_cli_cmd_new.infer_sol_home's ancestor walk from the test
   executable's own path escapes dune's _build sandbox and lands on the
   real checkout root (confirmed: this test passes under plain `dune
   test`), so this exercises the actual production file, not a fixture. *)
let test_alloy_values_yaml_against_real_file () =
  match Sol_cli_cmd_new.infer_sol_home () with
  | None -> Alcotest.fail "could not resolve SOL_HOME against the real checkout"
  | Some _ ->
      let yaml = Sol_cli_dev_observability.alloy_values_yaml () in
      assert_contains "helm values shape" yaml "configMap:";
      assert_contains "content block" yaml "content: |-";
      assert_contains "pod discovery" yaml "discovery.kubernetes \"pods\"";
      assert_contains "kubernetes API tailing" yaml
        "loki.source.kubernetes \"pods\"";
      assert_contains "write component" yaml "loki.write \"default\"";
      assert_contains "push url" yaml "http://loki:3100/loki/api/v1/push";
      assert_contains "taxonomy label: workspace" yaml
        "__meta_kubernetes_pod_label_workspace";
      assert_contains "taxonomy label: release" yaml
        "__meta_kubernetes_pod_label_release";
      check_bool "no basic_auth block for sol dev up" false
        (contains "basic_auth" yaml)

(* CODE_LAYER-006: this is the exact regression class the "found along the
   way" YAML indentation bug was -- alloy_config_river's old template put
   the `content: |-` block scalar's body at the SAME indentation as its
   own key, which no test caught (every assertion above only checks
   substring presence, not YAML well-formedness). Not a full YAML parser
   (no new dependency, consistent with this project's pure-OCaml test
   suite) -- just the one structural invariant that actually broke: every
   line of a `|-` block scalar's body must be indented strictly more than
   its key. *)
let leading_spaces line =
  let n = String.length line in
  let rec go i = if i < n && line.[i] = ' ' then go (i + 1) else i in
  go 0

let test_alloy_values_yaml_is_valid_block_scalar_shape () =
  let yaml = Sol_cli_dev_observability.alloy_values_yaml () in
  let lines = String.split_on_char '\n' yaml in
  let key_line = List.find (fun l -> contains "content: |-" l) lines in
  let key_indent = leading_spaces key_line in
  let rec check = function
    | [] -> ()
    | line :: rest when line == key_line ->
        List.iter
          (fun body_line ->
            if String.trim body_line <> "" then
              check_bool
                (Printf.sprintf "body line more indented than key (key=%d): %S"
                   key_indent body_line)
                true
                (leading_spaces body_line > key_indent))
          rest
    | _ :: rest -> check rest
  in
  check lines

let () =
  Alcotest.run "dev_observability"
    [
      ( "grafana",
        [
          Alcotest.test_case "dashboard configmap" `Quick
            test_dashboard_configmap;
          Alcotest.test_case "prometheus datasource configmap" `Quick
            test_prometheus_datasource_configmap;
          Alcotest.test_case "loki datasource configmap" `Quick
            test_loki_datasource_configmap;
          Alcotest.test_case "tempo datasource configmap" `Quick
            test_tempo_datasource_configmap;
        ] );
      ( "alloy",
        [
          Alcotest.test_case "render expands taxonomy loop" `Quick
            test_alloy_render_expands_taxonomy_loop;
          Alcotest.test_case "render omits empty basic_auth" `Quick
            test_alloy_render_omits_basic_auth_when_empty;
          Alcotest.test_case "render includes set basic_auth" `Quick
            test_alloy_render_includes_basic_auth_when_set;
          Alcotest.test_case "values yaml (real file)" `Quick
            test_alloy_values_yaml_against_real_file;
          Alcotest.test_case "values yaml is valid block scalar shape" `Quick
            test_alloy_values_yaml_is_valid_block_scalar_shape;
        ] );
    ]
