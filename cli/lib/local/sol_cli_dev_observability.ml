module Y = Sol_cli_yaml

let configmap_yaml ~name ~namespace ~labels ~data =
  Y.render
    [ Y.document
        (Y.map
           [ "apiVersion", Y.string "v1"
           ; "kind", Y.string "ConfigMap"
           ; ( "metadata"
             , Y.map
                 [ "name", Y.string name
                 ; "namespace", Y.string namespace
                 ; "labels", Y.map (List.map (fun (k, v) -> k, Y.quoted v) labels)
                 ] )
           ; "data", Y.map (List.map (fun (k, v) -> k, Y.literal v) data)
           ])
    ]
;;

let datasource_yaml fields =
  Y.to_string (Y.map [ "apiVersion", Y.int 1; "datasources", Y.list [ Y.map fields ] ])
;;

let tempo_datasource_uid = "tempo"

let prometheus_datasource_yaml ~namespace =
  datasource_yaml
    [ "name", Y.string "Prometheus"
    ; "type", Y.string "prometheus"
    ; "access", Y.string "proxy"
    ; ( "url"
      , Y.string
          (Printf.sprintf "http://prometheus-server.%s.svc.cluster.local:80" namespace) )
    ; "isDefault", Y.bool false
    ]
;;

open Result.Syntax

let read_asset path =
  match In_channel.with_open_bin path In_channel.input_all with
  | contents -> Ok contents
  | exception Sys_error msg -> Error (Printf.sprintf "cannot read %s" msg)
;;

let dashboard_names =
  [ "workspace-overview.json"
  ; "domain-overview.json"
  ; "service-template.json"
  ; "release-timeline.json"
  ; "target-infrastructure.json"
  ]
;;

let dashboard_configmap_yaml ~assets ~namespace =
  let* data =
    List.fold_left
      (fun acc name ->
         let* read = acc in
         let* json = read_asset (Sol_cli_platform_assets.dashboard assets name) in
         Ok ((name, json) :: read))
      (Ok [])
      dashboard_names
    |> Result.map List.rev
  in
  Ok
    (configmap_yaml
       ~name:"sol-grafana-dashboards"
       ~namespace
       ~labels:[ "grafana_dashboard", "1" ]
       ~data)
;;

let prometheus_datasource_configmap_yaml ~namespace =
  configmap_yaml
    ~name:"grafana-prometheus-datasource"
    ~namespace
    ~labels:[ "grafana_datasource", "1" ]
    ~data:[ "prometheus.yaml", prometheus_datasource_yaml ~namespace ]
;;

let tempo_datasource_yaml =
  datasource_yaml
    [ "name", Y.string "Tempo"
    ; "type", Y.string "tempo"
    ; "access", Y.string "proxy"
    ; "uid", Y.string tempo_datasource_uid
    ; "url", Y.string "http://tempo:3200"
    ; "isDefault", Y.bool false
    ]
;;

let tempo_datasource_configmap_yaml ~namespace =
  configmap_yaml
    ~name:"grafana-tempo-datasource"
    ~namespace
    ~labels:[ "grafana_datasource", "1" ]
    ~data:[ "tempo.yaml", tempo_datasource_yaml ]
;;

let loki_datasource_yaml =
  datasource_yaml
    [ "name", Y.string "Loki"
    ; "type", Y.string "loki"
    ; "access", Y.string "proxy"
    ; "url", Y.string "http://loki:3100"
    ; "isDefault", Y.bool false
    ; ( "jsonData"
      , Y.map
          [ ( "derivedFields"
            , Y.list
                [ Y.map
                    [ "datasourceUid", Y.string tempo_datasource_uid
                    ; "matcherRegex", Y.quoted "trace_id=([0-9a-f]{32})"
                    ; "name", Y.string "TraceID"
                    ; "url", Y.quoted "${__value.raw}"
                    ]
                ] )
          ] )
    ]
;;

let loki_datasource_configmap_yaml ~namespace =
  configmap_yaml
    ~name:"grafana-loki-datasource"
    ~namespace
    ~labels:[ "grafana_datasource", "1" ]
    ~data:[ "loki.yaml", loki_datasource_yaml ]
;;

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

let slice_between ~marker_start ~marker_end content =
  match find_substring ~needle:marker_start content with
  | None -> Error (Printf.sprintf "alloy template: marker not found: %S" marker_start)
  | Some s ->
    let inner_start = s + String.length marker_start in
    (match find_substring ~needle:marker_end content with
     | None -> Error (Printf.sprintf "alloy template: marker not found: %S" marker_end)
     | Some e when e < inner_start ->
       Error (Printf.sprintf "alloy template: %S found before %S" marker_end marker_start)
     | Some e ->
       let before = String.sub content 0 s in
       let inner = String.sub content inner_start (e - inner_start) in
       let after_start = e + String.length marker_end in
       let after = String.sub content after_start (String.length content - after_start) in
       Ok (before, inner, after))
;;

let basic_auth_if_start =
  {|%{ if loki_push_basic_auth_username != "" ~}
|}
;;

let basic_auth_if_end = "%{ endif ~}\n"

let render_alloy_config
      ~assets
      ~taxonomy_labels
      ~loki_push_url
      ~loki_push_basic_auth_username
      ~loki_push_basic_auth_password
  =
  let* content = read_asset (Sol_cli_platform_assets.alloy_template assets) in
  let* before, loop_body, after =
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
  let* before, inner, after =
    slice_between ~marker_start:basic_auth_if_start ~marker_end:basic_auth_if_end content
  in
  let content =
    before ^ (if loki_push_basic_auth_username = "" then "" else inner) ^ after
  in
  Ok
    (content
     |> replace_all ~pattern:"${loki_push_url}" ~replacement:loki_push_url
     |> replace_all
          ~pattern:"${loki_push_basic_auth_username}"
          ~replacement:loki_push_basic_auth_username
     |> replace_all
          ~pattern:"${loki_push_basic_auth_password}"
          ~replacement:loki_push_basic_auth_password)
;;

let alloy_values_yaml ~assets =
  let* config =
    render_alloy_config
      ~assets
      ~taxonomy_labels:[ "workspace"; "env"; "domain"; "service"; "primitive"; "release" ]
      ~loki_push_url:"http://loki:3100/loki/api/v1/push"
      ~loki_push_basic_auth_username:""
      ~loki_push_basic_auth_password:""
  in
  Ok
    (Y.to_string
       (Y.map [ "alloy", Y.map [ "configMap", Y.map [ "content", Y.literal config ] ] ]))
;;
