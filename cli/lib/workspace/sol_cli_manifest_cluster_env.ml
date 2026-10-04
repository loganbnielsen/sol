type kafka_transport =
  | Plaintext
  | Sasl_ssl

let kafka_transport ~production = if production then Sasl_ssl else Plaintext

let kafka_tls = function
  | Plaintext -> false
  | Sasl_ssl -> true
;;

let kafka_protocol_key = "KAFKA_SECURITY_PROTOCOL"

let kafka_transport_of_config config =
  match List.assoc_opt kafka_protocol_key config with
  | Some "sasl_ssl" -> Sasl_ssl
  | _ -> Plaintext
;;

let kafka_ca_mount_path = "/etc/sol/kafka"
let kafka_ca_file = kafka_ca_mount_path ^ "/ca.crt"
let kafka_ca_volume = "kafka-ca"
let kafka_ca_secret_key = "KAFKA_SSL_CA_CERT"
let kafka_sasl_password_key = "KAFKA_SASL_PASSWORD"
let kafka_sasl_username = "sol-workloads"
let kafka_sasl_mechanism = "SCRAM-SHA-256"
let kafka_brokers = "redpanda.redpanda.svc.cluster.local:9093"
let schema_registry_host = "redpanda.redpanda.svc.cluster.local:8081"
let redpanda_admin_host = "redpanda.redpanda.svc.cluster.local:9644"

let kafka_posture_env = function
  | Plaintext -> [ "KAFKA_SECURITY_PROTOCOL", "plaintext" ]
  | Sasl_ssl ->
    [ "KAFKA_SECURITY_PROTOCOL", "sasl_ssl"
    ; "KAFKA_SASL_MECHANISM", kafka_sasl_mechanism
    ; "KAFKA_SASL_USERNAME", kafka_sasl_username
    ; "KAFKA_SSL_CA_LOCATION", kafka_ca_file
    ]
;;

let cluster_env transport =
  let scheme =
    match transport with
    | Plaintext -> "http"
    | Sasl_ssl -> "https"
  in
  kafka_posture_env transport
  @ [ "KAFKA_BROKERS", kafka_brokers
    ; "SCHEMA_REGISTRY_URL", Printf.sprintf "%s://%s" scheme schema_registry_host
    ; "REDPANDA_ADMIN_URL", Printf.sprintf "%s://%s" scheme redpanda_admin_host
    ; "LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100"
    ; ( "PUSHGATEWAY_URL"
      , "http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091" )
    ; "TEMPO_URL", "http://tempo.monitoring.svc.cluster.local:4318"
    ]
;;

let default_cluster_env = cluster_env Plaintext

let production_kafka_config =
  [ kafka_protocol_key, "sasl_ssl"
  ; "KAFKA_SASL_MECHANISM", kafka_sasl_mechanism
  ; "KAFKA_SASL_USERNAME", kafka_sasl_username
  ; "KAFKA_SSL_CA_LOCATION", kafka_ca_file
  ; "SCHEMA_REGISTRY_URL", Printf.sprintf "https://%s" schema_registry_host
  ; "REDPANDA_ADMIN_URL", Printf.sprintf "https://%s" redpanda_admin_host
  ]
;;

let kafka_required_secret_keys = function
  | Plaintext -> []
  | Sasl_ssl -> [ kafka_sasl_password_key; kafka_ca_secret_key ]
;;
