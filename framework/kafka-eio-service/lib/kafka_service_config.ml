let of_env () =
  let env_or name default =
    match Sys.getenv_opt name with
    | Some v when String.length v > 0 -> v
    | _ -> default
  in
  let brokers_str = env_or "KAFKA_BROKERS" "localhost:9092" in
  let topic_durability =
    match env_or "SOL_KAFKA_DURABILITY" "broker-default" with
    | "broker-default" -> Ok Kafka_service_intf.Broker_default
    | "single-broker-loss" -> Ok Kafka_service_intf.Single_broker_loss
    | value ->
      Error
        (Printf.sprintf
           "unknown SOL_KAFKA_DURABILITY %S (expected broker-default or \
            single-broker-loss)"
           value)
  in
  match topic_durability, Kafka.Security.of_env () with
  | Error msg, _ | _, Error msg -> Error msg
  | Ok topic_durability, Ok security ->
    Ok
      { Kafka_service_intf.brokers = String.split_on_char ',' brokers_str
      ; schema_registry_url = env_or "SCHEMA_REGISTRY_URL" "http://localhost:8081"
      ; admin_url = env_or "REDPANDA_ADMIN_URL" "http://localhost:9644"
      ; linger_ms = 50
      ; partitions = 1
      ; topic_durability
      ; security
      }
;;
