let of_env () =
  let env_or name default =
    match Sys.getenv_opt name with
    | Some v when String.length v > 0 -> v
    | _ -> default
  in
  (* BUG-055 / FND-0054: the substrate addresses are stated, never defaulted to
     localhost. In a pod nothing listens there, so a config that omitted one used
     to fail later with an error naming localhost instead of the missing variable.
     Sol-rendered manifests and [sol local run] set all three. *)
  let required = [ "KAFKA_BROKERS"; "SCHEMA_REGISTRY_URL"; "REDPANDA_ADMIN_URL" ] in
  let addresses =
    match
      List.filter
        (fun name ->
           match Sys.getenv_opt name with
           | Some v -> String.trim v = ""
           | None -> true)
        required
    with
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
  (* SEC-007 / FND-0039: the transport posture is stated, never defaulted.
     [Kafka.Security.of_env] reads an absent protocol as plaintext, which let
     every environment ship plaintext without saying so; Sol-rendered manifests
     now always set it, and anything else must too (plaintext locally). *)
  let declared_protocol =
    match Sys.getenv_opt "KAFKA_SECURITY_PROTOCOL" with
    | Some v when String.trim v <> "" -> Ok ()
    | _ ->
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
      ; partitions = 1
      ; topic_durability
      ; security
      }
;;
