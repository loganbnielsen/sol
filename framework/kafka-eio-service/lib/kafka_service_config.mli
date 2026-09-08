(** Build a [Kafka_service_intf.config] from environment variables. See
    [Kafka_service.config_of_env] (the public re-export) for the full list
    of variables and defaults. *)
val of_env : unit -> (Kafka_service_intf.config, string) result
