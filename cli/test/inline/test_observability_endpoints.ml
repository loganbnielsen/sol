let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let test_cluster_env_declares_the_platform_observability_endpoints () =
  let env = Sol_cli_manifest.default_cluster_env in
  check_string
    "LOKI_URL"
    "http://loki.monitoring.svc.cluster.local:3100"
    (List.assoc "LOKI_URL" env);
  check_string
    "PUSHGATEWAY_URL"
    "http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091"
    (List.assoc "PUSHGATEWAY_URL" env);
  check_string
    "TEMPO_URL"
    "http://tempo.monitoring.svc.cluster.local:4318"
    (List.assoc "TEMPO_URL" env)
;;

let%test "cluster env: projects the declared observability endpoints" =
  test_cluster_env_declares_the_platform_observability_endpoints ()
;;
