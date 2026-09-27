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
  Alcotest.(check (list string))
    "each component, in install order"
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
  Alcotest.(check (list string)) "nothing declared" [ "ingress-nginx" ] (labels (req ()));
  Alcotest.(check bool)
    "no repositories needed"
    false
    (Sol_cli_local_platform.needs_any_chart (req ()))
;;

let test_declared_postgres () =
  Alcotest.(check (list string))
    "postgres and the ingress"
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
  Alcotest.(check (option string))
    "a component's merged values"
    (Some "redpanda-values")
    (find "Redpanda").values_yaml;
  Alcotest.(check (option string))
    "Alloy's rendered values"
    (Some "alloy-values")
    (find "Alloy").values_yaml;
  Alcotest.(check (option string))
    "pinned, matching the platform module"
    (Some "26.1.11")
    (find "Redpanda").version
;;

let forwards req =
  Sol_cli_local_platform.endpoints ~req
  |> List.map (fun (e : Sol_cli_local_platform.endpoint) -> e.forward.name)
;;

let test_endpoints_nothing_declared () =
  Alcotest.(check (list string)) "ingress only" [ "ingress" ] (forwards (req ()))
;;

let test_endpoints_everything () =
  Alcotest.(check (list string))
    "every forward, in the summary's order"
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
  Alcotest.(check int)
    "no two forwards share a host port"
    (List.length ports)
    (List.length (List.sort_uniq compare ports));
  Alcotest.(check bool) "not sol up's 8080" false (List.mem 8080 ports)
;;

let test_k3d_api_version () =
  let env daemon_min = Sol_cli_local_cluster.api_version_env ~daemon_min in
  Alcotest.(check (list (pair string string)))
    "Docker 29's floor"
    [ "DOCKER_API_VERSION", "1.44" ]
    (env "1.44\n");
  Alcotest.(check (list (pair string string))) "an older daemon" [] (env "1.24");
  Alcotest.(check (list (pair string string))) "the floor itself" [] (env "1.43");
  Alcotest.(check (list (pair string string))) "unreadable" [] (env "");
  Alcotest.(check bool)
    "numeric, not lexical"
    true
    (Sol_cli_local_cluster.version_gt "1.100" "1.43")
;;

let () =
  Alcotest.run
    "local platform"
    [ ( "REFAC-139 part B"
      , [ Alcotest.test_case "everything" `Quick test_everything
        ; Alcotest.test_case "ingress always" `Quick test_ingress_always
        ; Alcotest.test_case "declared postgres" `Quick test_declared_postgres
        ; Alcotest.test_case
            "values from the assets"
            `Quick
            test_values_come_from_the_assets
        ] )
    ; ( "REFAC-139 part F"
      , [ Alcotest.test_case
            "no endpoints declared"
            `Quick
            test_endpoints_nothing_declared
        ; Alcotest.test_case "every endpoint" `Quick test_endpoints_everything
        ; Alcotest.test_case "distinct host ports" `Quick test_endpoint_ports_are_distinct
        ; Alcotest.test_case "k3d API version" `Quick test_k3d_api_version
        ] )
    ]
;;
