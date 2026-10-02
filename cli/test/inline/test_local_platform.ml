let assets =
  { Sol_cli_local_platform.component_values =
      List.map (fun c -> c, c ^ "-values") Sol_cli_local_platform.components
  ; alloy_values = "alloy-values"
  ; dashboards = "dashboards"
  }
;;

let req ?(kafka = false) ?(postgres = false) ?(observability = false) () =
  { Sol_cli_workspace.kafka
  ; postgres
  ; loki = observability
  ; prometheus = observability
  ; tempo = observability
  }
;;

let labels req =
  Sol_cli_local_platform.releases ~req ~assets
  |> List.map (fun (r : Sol_cli_local_platform.release) -> r.label)
;;

let test_everything () =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"each component, in install order"
    [ "Redpanda"
    ; "PostgreSQL"
    ; "Loki"
    ; "Grafana"
    ; "Alloy"
    ; "Tempo"
    ; "Prometheus"
    ; "ingress-nginx"
    ]
    (labels (req ~kafka:true ~postgres:true ~observability:true ()))
;;

let test_ingress_always () =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"nothing declared"
    [ "ingress-nginx" ]
    (labels (req ()));
  Windtrap.equal
    Windtrap.bool
    ~msg:"no repositories needed"
    false
    (Sol_cli_local_platform.needs_any_chart (req ()))
;;

let test_declared_postgres () =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"postgres and the ingress"
    [ "PostgreSQL"; "ingress-nginx" ]
    (labels (req ~postgres:true ()))
;;

let test_values_come_from_the_assets () =
  let find label =
    Sol_cli_local_platform.releases
      ~req:(req ~kafka:true ~postgres:true ~observability:true ())
      ~assets
    |> List.find (fun (r : Sol_cli_local_platform.release) -> r.label = label)
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"a component's merged values"
    (Some "redpanda-values")
    (find "Redpanda").values_yaml;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"Alloy's rendered values"
    (Some "alloy-values")
    (find "Alloy").values_yaml;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"pinned, matching the platform module"
    (Some "26.1.11")
    (find "Redpanda").version
;;

let forwards req =
  Sol_cli_local_platform.endpoints ~req
  |> List.map (fun (e : Sol_cli_local_platform.endpoint) -> e.forward.name)
;;

let test_endpoints_nothing_declared () =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"ingress only"
    [ "ingress" ]
    (forwards (req ()))
;;

let test_endpoints_everything () =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"every forward, in the summary's order"
    [ "kafka"
    ; "schema-registry"
    ; "postgres"
    ; "loki"
    ; "grafana"
    ; "prometheus"
    ; "pushgateway"
    ; "tempo"
    ; "tempo-query"
    ; "ingress"
    ]
    (forwards (req ~kafka:true ~postgres:true ~observability:true ()))
;;

let test_endpoint_ports_are_distinct () =
  let ports =
    Sol_cli_local_platform.endpoints
      ~req:(req ~kafka:true ~postgres:true ~observability:true ())
    |> List.map (fun (e : Sol_cli_local_platform.endpoint) -> e.forward.local_port)
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"no two forwards share a host port"
    (List.length ports)
    (List.length (List.sort_uniq compare ports));
  Windtrap.equal Windtrap.bool ~msg:"not sol up's 8080" false (List.mem 8080 ports)
;;

let test_k3d_api_version () =
  let env daemon_min = Sol_cli_local_cluster.api_version_env ~daemon_min in
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"Docker 29's floor"
    [ "DOCKER_API_VERSION", "1.44" ]
    (env "1.44\n");
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"an older daemon"
    []
    (env "1.24");
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"the floor itself"
    []
    (env "1.43");
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"unreadable"
    []
    (env "");
  Windtrap.equal
    Windtrap.bool
    ~msg:"numeric, not lexical"
    true
    (Sol_cli_local_cluster.version_gt "1.100" "1.43")
;;

let%test "REFAC-139 part B: everything" = test_everything ()
let%test "REFAC-139 part B: ingress always" = test_ingress_always ()
let%test "REFAC-139 part B: declared postgres" = test_declared_postgres ()
let%test "REFAC-139 part B: values from the assets" = test_values_come_from_the_assets ()
let%test "REFAC-139 part F: no endpoints declared" = test_endpoints_nothing_declared ()
let%test "REFAC-139 part F: every endpoint" = test_endpoints_everything ()
let%test "REFAC-139 part F: distinct host ports" = test_endpoint_ports_are_distinct ()
let%test "REFAC-139 part F: k3d API version" = test_k3d_api_version ()
