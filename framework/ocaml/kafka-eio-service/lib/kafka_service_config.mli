val of_env : unit -> (Kafka_service_intf.config, string) result

(** The PEM bundle at KAFKA_SSL_CA_LOCATION, the deployment's declared trust
    root for Sol-managed HTTPS endpoints behind the private CA. [None] when the
    deployment declares no private CA. *)
val declared_ca_file : unit -> string option
