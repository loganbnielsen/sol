let indent_block s =
  s
  |> String.split_on_char '\n'
  |> List.map (fun line -> "    " ^ line)
  |> String.concat "\n"
;;

let configmap_yaml ~name ~namespace ~labels ~data =
  let labels_yaml =
    labels
    |> List.map (fun (k, v) -> Printf.sprintf "    %s: %S" k v)
    |> String.concat "\n"
  in
  let data_yaml =
    data
    |> List.map (fun (k, v) -> Printf.sprintf "  %s: |-\n%s" k (indent_block v))
    |> String.concat "\n"
  in
  Printf.sprintf
    {|apiVersion: v1
kind: ConfigMap
metadata:
  name: %s
  namespace: %s
  labels:
%s
data:
%s
|}
    name
    namespace
    labels_yaml
    data_yaml
;;

(* OBS-042: uid is pinned explicitly (rather than left for Grafana to derive
   from the datasource name) so grafana_loki_datasource's derivedFields entry
   below can reference it by a stable value. *)
let tempo_datasource_uid = "tempo"

let prometheus_datasource_yaml ~namespace =
  Printf.sprintf
    {|apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus-server.%s.svc.cluster.local:80
    isDefault: false|}
    namespace
;;

(* CODE_LAYER-007: cli/platform/infra/base/dashboards/*.json is now the single
   source of Sol's four generic Grafana dashboards -- both `sol dev up`
   (here) and cli/platform/infra/base/main.tf's `kubernetes_config_map.grafana_dashboards`
   (via Terraform's own `file(...)`) load from the same files, instead of
   a second, hand-synced OCaml copy per dashboard. Resolves SOL_HOME
   itself (same pattern as Sol_cli_platform_component.merged_values_yaml
   and render_alloy_config), reading each real file, not a fixture.

   The real files each carry a trailing newline the old OCaml string
   literals didn't -- not byte-identical to what those literals held, but
   equivalent post-render: configmap_yaml's `|-` (strip-chomped) block
   scalar discards trailing newlines on parse either way, confirmed live
   (`kubectl apply` on the new render came back "unchanged" against the
   cluster's existing ConfigMap). *)
let read_dashboard_json ~sol_home name =
  let path =
    Filename.concat sol_home (Filename.concat "cli/platform/infra/base/dashboards" name)
  in
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let dashboard_configmap_yaml ~namespace =
  let sol_home =
    match Sol_cli_cmd_new.infer_sol_home () with
    | Some dir -> dir
    | None ->
      Printf.eprintf
        "error: cannot locate the Sol monorepo root to read \
         cli/platform/infra/base/dashboards/*.json.\n";
      Printf.eprintf "  Set SOL_HOME to your Sol checkout and re-run:\n";
      Printf.eprintf "    export SOL_HOME=/path/to/sol\n";
      exit 1
  in
  let dashboard name = read_dashboard_json ~sol_home name in
  configmap_yaml
    ~name:"sol-grafana-dashboards"
    ~namespace
    ~labels:[ "grafana_dashboard", "1" ]
    ~data:
      [ "workspace-overview.json", dashboard "workspace-overview.json"
      ; "domain-overview.json", dashboard "domain-overview.json"
      ; "service-template.json", dashboard "service-template.json"
      ; "release-timeline.json", dashboard "release-timeline.json"
      ]
;;

let prometheus_datasource_configmap_yaml ~namespace =
  configmap_yaml
    ~name:"grafana-prometheus-datasource"
    ~namespace
    ~labels:[ "grafana_datasource", "1" ]
    ~data:[ "prometheus.yaml", prometheus_datasource_yaml ~namespace ]
;;

(* OBS-042: Tempo query API (chart/service port 3200, distinct from the
   OTLP/HTTP ingestion port 4318 obs-tempo-eio pushes spans to) exposed as a
   Grafana datasource, mirroring prometheus_datasource_yaml above. *)
let tempo_datasource_yaml =
  Printf.sprintf
    {|apiVersion: 1
datasources:
  - name: Tempo
    type: tempo
    access: proxy
    uid: %s
    url: http://tempo:3200
    isDefault: false|}
    tempo_datasource_uid
;;

let tempo_datasource_configmap_yaml ~namespace =
  configmap_yaml
    ~name:"grafana-tempo-datasource"
    ~namespace
    ~labels:[ "grafana_datasource", "1" ]
    ~data:[ "tempo.yaml", tempo_datasource_yaml ]
;;

(* OBS-039: loki-stack's bundled Grafana subchart auto-provisioned a "Loki"
   datasource itself (a chart-internal template, not just the generic
   sidecar-ConfigMap convention). Now that `sol dev up` installs the
   standalone `grafana` chart instead, that auto-provisioning is gone and
   must be replaced explicitly -- every dashboard above references a
   datasource named exactly "Loki". Matches
   cli/platform/infra/base's helm_release.grafana bundle:
   kubernetes_config_map.grafana_loki_datasource. *)
(* OBS-042: derivedFields turns a trace_id in a Loki log line into a click-
   through to its Tempo waterfall. matcherRegex must match obs-loki-eio's
   real logfmt output -- trace_id is an unquoted 32-hex-char field
   (Obs_loki.trace_id_hex, "%016Lx%016Lx"), never quoted since hex digits
   never trigger Obs_loki.logfmt_val's quoting rule. *)
let loki_datasource_yaml =
  Printf.sprintf
    {|apiVersion: 1
datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    isDefault: false
    jsonData:
      derivedFields:
        - datasourceUid: %s
          matcherRegex: "trace_id=([0-9a-f]{32})"
          name: TraceID
          url: "${__value.raw}"|}
    tempo_datasource_uid
;;

let loki_datasource_configmap_yaml ~namespace =
  configmap_yaml
    ~name:"grafana-loki-datasource"
    ~namespace
    ~labels:[ "grafana_datasource", "1" ]
    ~data:[ "loki.yaml", loki_datasource_yaml ]
;;

(* CODE_LAYER-006: cli/platform/infra/base/alloy/logs.alloy.tftpl is now the
   single source of Alloy's River log-shipping config -- both `sol dev up`
   (here) and cli/platform/infra/base/main.tf's `helm_release.alloy` (via
   Terraform's own `templatefile()`) render from that one file. This is a
   minimal, literal-substring templater for exactly the three constructs
   that file uses: `${var}` interpolation, one
   `%{ for x in taxonomy_labels ~}...%{ endfor ~}` loop, and one
   `%{ if cond ~}...%{ endif ~}` conditional gated on whether
   loki_push_basic_auth_username is non-empty -- not a general HCL
   template engine. If logs.alloy.tftpl grows a construct this doesn't
   handle, this function needs a matching update, the same way any second
   reader of a file format does when the format changes. *)

let find_substring ~needle haystack =
  let hn = String.length haystack
  and nn = String.length needle in
  let rec go i =
    if i + nn > hn
    then None
    else if String.sub haystack i nn = needle
    then Some i
    else go (i + 1)
  in
  if nn = 0 then Some 0 else go 0
;;

let replace_all ~pattern ~replacement s =
  let pn = String.length pattern in
  if pn = 0
  then s
  else (
    let sn = String.length s in
    let buf = Buffer.create sn in
    let rec go i =
      if i > sn - pn
      then Buffer.add_string buf (String.sub s i (sn - i))
      else if String.sub s i pn = pattern
      then (
        Buffer.add_string buf replacement;
        go (i + pn))
      else (
        Buffer.add_char buf s.[i];
        go (i + 1))
    in
    go 0;
    Buffer.contents buf)
;;

(* Splits [content] into the text before [marker_start], the text strictly
   between the two markers, and the text after [marker_end] (both markers
   themselves excluded from all three parts). Raises if either marker is
   missing or out of order -- a malformed/changed .tftpl should fail
   loudly at render time, not silently produce wrong River config. *)
let slice_between ~marker_start ~marker_end content =
  match find_substring ~needle:marker_start content with
  | None ->
    invalid_arg (Printf.sprintf "alloy template: marker not found: %S" marker_start)
  | Some s ->
    let inner_start = s + String.length marker_start in
    (match find_substring ~needle:marker_end content with
     | None ->
       invalid_arg (Printf.sprintf "alloy template: marker not found: %S" marker_end)
     | Some e when e < inner_start ->
       invalid_arg
         (Printf.sprintf "alloy template: %S found before %S" marker_end marker_start)
     | Some e ->
       let before = String.sub content 0 s in
       let inner = String.sub content inner_start (e - inner_start) in
       let after_start = e + String.length marker_end in
       let after = String.sub content after_start (String.length content - after_start) in
       before, inner, after)
;;

let basic_auth_if_start =
  {|%{ if loki_push_basic_auth_username != "" ~}
|}
;;

let basic_auth_if_end = "%{ endif ~}\n"

let render_alloy_config
      ~sol_home
      ~taxonomy_labels
      ~loki_push_url
      ~loki_push_basic_auth_username
      ~loki_push_basic_auth_password
  =
  let path = Filename.concat sol_home "cli/platform/infra/base/alloy/logs.alloy.tftpl" in
  let ic = open_in_bin path in
  let content =
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  in
  let before, loop_body, after =
    slice_between
      ~marker_start:"%{ for label in taxonomy_labels ~}\n"
      ~marker_end:"%{ endfor ~}\n"
      content
  in
  let expanded_loop =
    taxonomy_labels
    |> List.map (fun label ->
      replace_all ~pattern:"${label}" ~replacement:label loop_body)
    |> String.concat ""
  in
  let content = before ^ expanded_loop ^ after in
  let before, inner, after =
    slice_between ~marker_start:basic_auth_if_start ~marker_end:basic_auth_if_end content
  in
  let content =
    before ^ (if loki_push_basic_auth_username = "" then "" else inner) ^ after
  in
  content
  |> replace_all ~pattern:"${loki_push_url}" ~replacement:loki_push_url
  |> replace_all
       ~pattern:"${loki_push_basic_auth_username}"
       ~replacement:loki_push_basic_auth_username
  |> replace_all
       ~pattern:"${loki_push_basic_auth_password}"
       ~replacement:loki_push_basic_auth_password
;;

(* `sol dev up`'s local profile: push straight to the in-cluster Loki, no
   basic auth (`sol dev up` has no "external backend" concept), the same
   fixed taxonomy label set cli/platform/infra/base/main.tf's
   local.observability_taxonomy_labels passes for every profile.
   Resolves the Sol monorepo root itself (same resolution
   Sol_cli_platform_component.merged_values_yaml and `sol cloud`'s
   resolve_sol_home already use) rather than pushing that onto the
   caller. *)
let alloy_values_yaml () =
  let sol_home =
    match Sol_cli_cmd_new.infer_sol_home () with
    | Some dir -> dir
    | None ->
      Printf.eprintf
        "error: cannot locate the Sol monorepo root to read \
         cli/platform/infra/base/alloy/logs.alloy.tftpl.\n";
      Printf.eprintf "  Set SOL_HOME to your Sol checkout and re-run:\n";
      Printf.eprintf "    export SOL_HOME=/path/to/sol\n";
      exit 1
  in
  (* CODE_LAYER-006: found along the way -- `content: |-`'s own indent here
     is 4 spaces (nested under alloy/configMap), so indent_block's flat
     4-space content indent left the block scalar body at the SAME column
     as its key, which real YAML parsers reject (confirmed with PyYAML: a
     block scalar's content must be indented strictly more than its key,
     not equal). Pre-existing, not introduced by this change -- the prior
     alloy_config_river went through the identical indent_block + template
     shape. Indenting 6 spaces here (2 more than the key) instead of
     reusing indent_block, which other configmap_yaml callers rely on at
     their own, already-correct nesting depth. *)
  Printf.sprintf
    {|alloy:
  configMap:
    content: |-
%s
|}
    (render_alloy_config
       ~sol_home
       ~taxonomy_labels:[ "workspace"; "domain"; "service"; "primitive"; "release" ]
       ~loki_push_url:"http://loki:3100/loki/api/v1/push"
       ~loki_push_basic_auth_username:""
       ~loki_push_basic_auth_password:""
     |> String.split_on_char '\n'
     |> List.map (fun line -> "      " ^ line)
     |> String.concat "\n")
;;
