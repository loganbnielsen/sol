let setting name =
  match Sys.getenv_opt name with
  | None -> None
  | Some value ->
    (match String.trim value with
     | "" -> None
     | trimmed -> Some trimmed)
;;

(* The deployment's declared trust root for Sol-managed HTTPS endpoints behind
   the private CA: the same KAFKA_SSL_CA_LOCATION Sol projects for the Kafka
   transport. Optional — when unset the system store is used. *)
let declared_ca_file () = setting "KAFKA_SSL_CA_LOCATION"

let of_env () =
  let env_or name default = Option.value (setting name) ~default in
  let required = [ "KAFKA_BROKERS"; "SCHEMA_REGISTRY_URL"; "REDPANDA_ADMIN_URL" ] in
  let addresses =
    match List.filter (fun name -> Option.is_none (setting name)) required with
    | [] -> Ok ()
    | missing ->
      Error
        (Printf.sprintf
           "%s not set: state the Kafka substrate addresses explicitly (Sol-rendered \
            manifests and `sol local run` set them; locally e.g. \
            KAFKA_BROKERS=localhost:9092 SCHEMA_REGISTRY_URL=http://localhost:8081 \
            REDPANDA_ADMIN_URL=http://localhost:9644)"
           (String.concat ", " missing))
  in
  let brokers_str = env_or "KAFKA_BROKERS" "" in
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
  let declared_protocol =
    match setting "KAFKA_SECURITY_PROTOCOL" with
    | Some _ -> Ok ()
    | None ->
      Error
        "KAFKA_SECURITY_PROTOCOL is not set: state the Kafka transport posture \
         explicitly (plaintext | ssl | sasl_plaintext | sasl_ssl). Sol-rendered \
         manifests set it; for a local process use KAFKA_SECURITY_PROTOCOL=plaintext."
  in
  match addresses, declared_protocol, topic_durability, Kafka.Security.of_env () with
  | Error msg, _, _, _ | _, Error msg, _, _ | _, _, Error msg, _ | _, _, _, Error msg ->
    Error msg
  | Ok (), Ok (), Ok topic_durability, Ok security ->
    Ok
      { Kafka_service_intf.brokers = String.split_on_char ',' brokers_str
      ; schema_registry_url = env_or "SCHEMA_REGISTRY_URL" ""
      ; admin_url = env_or "REDPANDA_ADMIN_URL" ""
      ; linger_ms = 50
      ; topic_durability
      ; security
      }
;;
