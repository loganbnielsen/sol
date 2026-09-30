module type MESSAGE = Kafka_service_intf.MESSAGE

type topic_name = Kafka_service_intf.topic_name

type error =
  | Invalid_topic_name of string * string
  | Config of string
  | Create of Kafka.Error.t
  | Topic_metadata of topic_name * string
  | Partition_count_reduction of
      { topic_name : topic_name
      ; current : int
      ; requested : int
      }
  | Insufficient_replication of
      { topic_name : topic_name
      ; current : int
      ; required : int
      }
  | Provision_topic of topic_name * Kafka.Error.t
  | Schema_registry of topic_name * string

let topic_name_to_string = Kafka_service_intf.topic_name_to_string

let error_to_string = function
  | Invalid_topic_name (name, msg) -> Printf.sprintf "invalid topic name %S: %s" name msg
  | Config msg -> "config: " ^ msg
  | Create e -> "producer: " ^ Kafka.Error.to_string e
  | Topic_metadata (topic, msg) ->
    Printf.sprintf
      "could not query topic '%s' metadata: %s"
      (topic_name_to_string topic)
      msg
  | Partition_count_reduction { topic_name; current; requested } ->
    Printf.sprintf
      "partition count for topic '%s' cannot be reduced from %d to %d; delete the topic \
       first if this change is intentional"
      (topic_name_to_string topic_name)
      current
      requested
  | Insufficient_replication { topic_name; current; required } ->
    Printf.sprintf
      "topic '%s' has replication factor %d; %d is required for single-broker-loss \
       durability"
      (topic_name_to_string topic_name)
      current
      required
  | Provision_topic (topic, e) ->
    Printf.sprintf
      "could not provision topic %s: %s"
      (topic_name_to_string topic)
      (Kafka.Error.to_string e)
  | Schema_registry (topic, msg) ->
    Printf.sprintf "schema registry for topic %s: %s" (topic_name_to_string topic) msg
;;

let topic_name name =
  Kafka_service_intf.topic_name name
  |> Result.map_error (fun msg -> Invalid_topic_name (name, msg))
;;

let topic_name_exn name =
  match topic_name name with
  | Ok topic -> topic
  | Error e -> invalid_arg (error_to_string e)
;;

type 'a topic = 'a Kafka_service_intf.topic =
  { name : topic_name
  ; schema_id : int
  ; partitions : int
  ; key : 'a -> string option
  ; encode : 'a -> Yojson.Safe.t
  ; decode : Yojson.Safe.t -> ('a, string) result
  }

type topic_durability = Kafka_service_intf.topic_durability =
  | Broker_default
  | Single_broker_loss

type config = Kafka_service_intf.config =
  { brokers : string list
  ; schema_registry_url : string
  ; admin_url : string
  ; linger_ms : int
  ; topic_durability : topic_durability
  ; security : Kafka.Security.t
  }

type t = Kafka_service_intf.t =
  { producer : Kafka.Producer.t
  ; brokers : string list
  ; schema_registry_url : string
  ; admin_url : string
  ; topic_durability : topic_durability
  ; security : Kafka.Security.t
  }

type decode_error_policy = Kafka_service_intf.decode_error_policy =
  | Route_to_dlq
  | Ack_and_drop

module Schema = struct
  let check ~net ~clock ~registry_url (module M : MESSAGE) =
    let topic = M.topic_name in
    let message = (module M : MESSAGE) in
    Kafka_service_schema.Schema.check ~net ~clock ~registry_url message
    |> Result.map_error (fun msg -> Schema_registry (topic, msg))
  ;;

  let rec check_all ~net ~clock ~registry_url = function
    | [] -> Ok ()
    | (module M : MESSAGE) :: rest ->
      let message = (module M : MESSAGE) in
      let open Result.Syntax in
      let* () = check ~net ~clock ~registry_url message in
      check_all ~net ~clock ~registry_url rest
  ;;

  let register ~net ~clock ~registry_url (module M : MESSAGE) =
    Kafka_service_schema.register_contract
      net
      ~clock
      ~registry_url
      ~topic_name:(topic_name_to_string M.topic_name)
      ~schema:M.schema
    |> Result.map_error (fun msg -> Schema_registry (M.topic_name, msg))
  ;;

  let resolve ~net ~clock ~registry_url (module M : MESSAGE) =
    let topic = M.topic_name in
    match
      Kafka_service_schema.registered_schema
        net
        ~clock
        ~registry_url
        ~topic_name:(topic_name_to_string topic)
    with
    | Error msg -> Error (Schema_registry (topic, msg))
    | Ok (registered : Kafka_service_schema.registered) ->
      if String.equal registered.schema M.schema
      then Ok registered.id
      else
        Error
          (Schema_registry
             ( topic
             , "the registered schema differs from the declared contract; register the \
                contract through the deployment lifecycle (sol plan / sol deploy), not \
                at runtime" ))
  ;;

  type compatibility_response = Kafka_service_schema.compatibility_response =
    { is_compatible : bool }

  type registration_response = Kafka_service_schema.registration_response = { id : int }

  let is_subject_not_found = Kafka_service_schema.Schema.is_subject_not_found
  let decode_compatibility_response = Kafka_service_schema.decode_compatibility_response
  let decode_registration_response = Kafka_service_schema.decode_registration_response
end

module Confluent_wire = Kafka_service_schema.Confluent_wire

module Contract = struct
  let event_json module_name (module M : MESSAGE) =
    `Assoc
      [ "module", `String module_name
      ; "topic", `String (topic_name_to_string M.topic_name)
      ; "partitions", `Int M.partitions
      ; "schema", `String M.schema
      ]
  ;;

  let projection events =
    `Assoc
      [ "version", `Int 1
      ; "events", `List (List.map (fun (name, m) -> event_json name m) events)
      ]
  ;;
end

module Dlq = struct
  type relay = Kafka_service_dlq.relay =
    { source : Kafka.Consumer.message
    ; headers : (string * string option) list
    }

  let sanitize_group_id = Kafka_service_dlq.sanitize_group_id
  let canonical_group_segment = Kafka_service_dlq.canonical_group_segment
  let dlq_topic_name = Kafka_service_dlq.dlq_topic_name
  let decode_failure_message = Kafka_service_dlq.decode_failure_message
  let route_decode_error = Kafka_service_dlq.route_decode_error
end

module Admin = struct
  type topic_partition_metadata = Kafka_service_intf.topic_partition_metadata =
    | Topic_not_found
    | Topic_partitions of
        { partitions : int
        ; replication_factor : int
        }

  type topic_partition_error = Kafka_service_intf.topic_partition_error

  let topic_partition_error_to_string = Kafka_service_intf.topic_partition_error_to_string
  let decode_topic_partitions = Kafka_service_intf.decode_topic_partitions
  let query_topic_partitions = Kafka_service_intf.query_topic_partitions
end

let encode_wire = Kafka_service_schema.encode_wire

let config_of_env () =
  Kafka_service_config.of_env () |> Result.map_error (fun msg -> Config msg)
;;

let create (cfg : config) ~sw =
  let producer_cfg : Kafka.Producer.config =
    { brokers = cfg.brokers
    ; delivery_mode = Kafka.Producer.At_least_once
    ; linger_ms = Some cfg.linger_ms
    ; security = cfg.security
    ; properties = []
    }
  in
  match Kafka.Producer.create producer_cfg ~sw with
  | Error e -> Error (Create e)
  | Ok producer ->
    Ok
      { Kafka_service_intf.producer
      ; brokers = cfg.brokers
      ; schema_registry_url = cfg.schema_registry_url
      ; admin_url = cfg.admin_url
      ; topic_durability = cfg.topic_durability
      ; security = cfg.security
      }
;;

let register
  : type a.
    t
    -> net:_ Eio.Net.t
    -> clock:_ Eio.Time.clock
    -> (module MESSAGE with type t = a)
    -> (a topic, error) result
  =
  fun svc ~net ~clock (module M) ->
  let open Result.Syntax in
  let raw_topic_name = topic_name_to_string M.topic_name in
  let* () =
    if M.partitions < 1
    then
      Error
        (Config
           (Printf.sprintf
              "topic '%s' declares %d partitions; a topic has at least one"
              raw_topic_name
              M.partitions))
    else Ok ()
  in
  let partition_guard () =
    match
      Kafka_service_intf.query_topic_partitions
        net
        ~clock
        ~admin_url:svc.admin_url
        ~topic_name:raw_topic_name
    with
    | Error e ->
      Error
        (Topic_metadata
           (M.topic_name, Kafka_service_intf.topic_partition_error_to_string e))
    | Ok Kafka_service_intf.Topic_not_found -> Ok ()
    | Ok (Kafka_service_intf.Topic_partitions { partitions = current; _ })
      when current > M.partitions ->
      Error
        (Partition_count_reduction
           { topic_name = M.topic_name; current; requested = M.partitions })
    | Ok (Kafka_service_intf.Topic_partitions { replication_factor; _ })
      when svc.topic_durability = Single_broker_loss && replication_factor < 3 ->
      Error
        (Insufficient_replication
           { topic_name = M.topic_name; current = replication_factor; required = 3 })
    | Ok (Kafka_service_intf.Topic_partitions _) -> Ok ()
  in
  let* () = partition_guard () in
  let* () =
    Kafka_service_intf.ensure_topic
      svc.producer
      ~topic_name:raw_topic_name
      ~partitions:M.partitions
      ~topic_durability:svc.topic_durability
    |> Result.map_error (fun msg -> Provision_topic (M.topic_name, msg))
  in
  let* () = Schema.check ~net ~clock ~registry_url:svc.schema_registry_url (module M) in
  let* schema_id =
    Schema.resolve ~net ~clock ~registry_url:svc.schema_registry_url (module M)
  in
  Ok
    { Kafka_service_intf.name = M.topic_name
    ; schema_id
    ; partitions = M.partitions
    ; key = M.key
    ; encode = M.encode
    ; decode = M.decode
    }
;;

let publish svc topic ?trace_ctx msg =
  let headers =
    match trace_ctx with
    | None -> []
    | Some ctx -> Obs_trace.inject_to_headers ctx []
  in
  let headers = List.map (fun (k, v) -> k, Some v) headers in
  let payload = encode_wire ~schema_id:topic.schema_id (topic.encode msg) in
  let key = Option.map Bytes.of_string (topic.key msg) in
  Kafka.Producer.produce_receipt
    svc.producer
    ~topic:(topic_name_to_string topic.name)
    ~value:(Some payload)
    ?key
    ~headers
    ()
;;

let default_on_decode_error = Kafka_service_intf.ack_and_drop_decode_error

let consume
      svc
      topic
      ~group_id
      ~sw
      ~clock
      ?hooks
      ?(decode_error_policy = Route_to_dlq)
      ?ot
      ?stop
      ~handler
      ()
  =
  let kafka_hooks = Option.value hooks ~default:Kafka.Consumer.default_hooks in
  let source_topic = topic_name_to_string topic.name in
  let dlq_topic = Kafka_service_dlq.dlq_topic_name ~source:source_topic ~group_id in
  let open Result.Syntax in
  let* () =
    match decode_error_policy with
    | Ack_and_drop -> Ok ()
    | Route_to_dlq ->
      Kafka_service_intf.ensure_topic
        svc.producer
        ~topic_name:dlq_topic
        ~partitions:topic.partitions
        ~topic_durability:svc.topic_durability
  in
  let publish_relay ~target_topic (relay : Kafka_service_dlq.relay) =
    Kafka.Producer.produce_await
      svc.producer
      ~topic:target_topic
      ~value:relay.source.value
      ?key:relay.source.key
      ~headers:relay.headers
      ()
  in
  let observe_decode_error =
    Kafka_service_intf.observe_decode_error ~ot ~topic_name:source_topic
  in
  let on_decode_error raw_msg e ~raw_bytes ~ack =
    match decode_error_policy with
    | Ack_and_drop ->
      observe_decode_error e ~raw_bytes ~disposition:`Dropped;
      default_on_decode_error e ~raw_bytes ~ack
    | Route_to_dlq ->
      observe_decode_error e ~raw_bytes ~disposition:`Dead_lettered;
      (match
         Kafka_service_dlq.route_decode_error
           ~dlq_topic
           ~raw_msg
           ~decode_error:e
           ~group_id
           ~publish:publish_relay
           ~ack
       with
       | Ok () -> Kafka.Consumer.Continue
       | Error ke -> Kafka.Consumer.Error ke)
  in
  let consumer_cfg : Kafka.Consumer.config =
    { brokers = svc.brokers
    ; group_id
    ; topics = [ source_topic ]
    ; offset_reset = Kafka.Consumer.Earliest
    ; auto_commit = false
    ; security = svc.security
    ; properties = []
    }
  in
  let* consumer = Kafka.Consumer.create ~hooks:kafka_hooks ~clock consumer_cfg ~sw in
  let decode_and_handle raw_msg ~ack =
    match Kafka_service_schema.decode_message topic raw_msg with
    | Error (e, raw_bytes) -> on_decode_error raw_msg e ~raw_bytes ~ack
    | Ok (msg, trace_ctx) -> handler msg ~ack ~trace_ctx
  in
  let result =
    Kafka.Consumer.consume consumer ~hooks:kafka_hooks ?stop ~handler:decode_and_handle ()
  in
  Kafka.Consumer.close consumer;
  result
;;
