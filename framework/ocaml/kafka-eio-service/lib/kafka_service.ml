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
  ; partitions : int
  ; topic_durability : topic_durability
  ; security : Kafka.Security.t
  }

type t = Kafka_service_intf.t =
  { producer : Kafka.Producer.t
  ; brokers : string list
  ; schema_registry_url : string
  ; admin_url : string
  ; partitions : int
  ; topic_durability : topic_durability
  ; security : Kafka.Security.t
  }

type consume_partitioned_error = Kafka_service_intf.consume_partitioned_error =
  | Consumer_error of Kafka.Error.t
  | Partition_errors of (int32 * Kafka.Error.t) list

type handler_error = Kafka_service_intf.handler_error =
  | Retry
  | Dead_letter of string
  | Kafka_error of Kafka.Error.t

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
      (match check ~net ~clock ~registry_url message with
       | Ok () -> check_all ~net ~clock ~registry_url rest
       | Error e -> Error e)
  ;;

  type compatibility_response = Kafka_service_schema.compatibility_response =
    { is_compatible : bool }

  type registration_response = Kafka_service_schema.registration_response = { id : int }

  let decode_compatibility_response = Kafka_service_schema.decode_compatibility_response
  let decode_registration_response = Kafka_service_schema.decode_registration_response
end

module Confluent_wire = Kafka_service_schema.Confluent_wire

module Retry_topics = struct
  type retry_action = Kafka_service_retry_topics.retry_action =
    | Ack
    | Forward_retry of
        { target : topic_name
        ; delay_s : float
        }
    | Forward_dlq of { target : topic_name }

  type relay = Kafka_service_retry_topics.relay =
    { source : Kafka.Consumer.message
    ; headers : (string * string option) list
    ; attempt : int
    ; delay_s : float
    }

  let parse_retry_metadata = Kafka_service_retry_topics.parse_retry_metadata
  let produce_backoff_s = Kafka_service_retry_topics.produce_backoff_s
  let retry_produce = Kafka_service_retry_topics.retry_produce
  let retry_message = Kafka_service_retry_topics.retry_message
  let dead_letter_message = Kafka_service_retry_topics.dead_letter_message

  let retry_decode_failure_message =
    Kafka_service_retry_topics.retry_decode_failure_message
  ;;

  let action_of_handler_error = Kafka_service_retry_topics.action_of_handler_error
  let execute_action = Kafka_service_retry_topics.execute_action
  let route_retry_decode_error = Kafka_service_retry_topics.route_retry_decode_error
  let relay_topic_name = Kafka_service_retry_topics.relay_topic_name
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
      ; partitions = cfg.partitions
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
  let ( let* ) = Result.bind in
  let raw_topic_name = topic_name_to_string M.topic_name in
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
      when current > svc.partitions ->
      Error
        (Partition_count_reduction
           { topic_name = M.topic_name; current; requested = svc.partitions })
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
      ~partitions:svc.partitions
      ~topic_durability:svc.topic_durability
    |> Result.map_error (fun msg -> Provision_topic (M.topic_name, msg))
  in
  let* schema_id =
    Kafka_service_schema.register_schema
      net
      ~clock
      ~registry_url:svc.schema_registry_url
      ~topic_name:raw_topic_name
      ~schema:M.schema
    |> Result.map_error (fun msg -> Schema_registry (M.topic_name, msg))
  in
  (match
     Kafka_service_schema.set_subject_compatibility
       net
       ~clock
       ~registry_url:svc.schema_registry_url
       ~topic_name:raw_topic_name
   with
   | Error e ->
     Printf.eprintf
       "warn: could not set schema compatibility for %s: %s\n%!"
       raw_topic_name
       e
   | Ok () -> ());
  Ok
    { Kafka_service_intf.name = M.topic_name
    ; schema_id
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
  Kafka.Producer.produce_await
    svc.producer
    ~topic:(topic_name_to_string topic.name)
    ~value:(Some payload)
    ~headers
    ()
;;

type retry_strategy =
  | In_memory of Kafka.Consumer.retry_policy
  | Retry_topics of Kafka.Consumer.retry_policy

let default_on_decode_error e ~raw_bytes:_ ~ack =
  Printf.eprintf "sol-worker: DECODE_ERROR skip=true error=%S\n%!" e;
  ignore (ack ());
  Kafka.Consumer.Continue
;;

let consume
      svc
      topic
      ~group_id
      ~sw
      ~clock
      ?(on_ready = ignore)
      ?(on_assigned = ignore)
      ?(on_revoked = ignore)
      ?(on_poll = ignore)
      ?(on_decode_error = default_on_decode_error)
      ?ot
      ~handler
      ()
  =
  let on_decode_error =
    Kafka_service_intf.wrap_on_decode_error
      ~ot
      ~topic_name:(topic_name_to_string topic.name)
      on_decode_error
  in
  let consumer_cfg : Kafka.Consumer.config =
    { brokers = svc.brokers
    ; group_id
    ; topics = [ topic_name_to_string topic.name ]
    ; offset_reset = Kafka.Consumer.Earliest
    ; auto_commit = false
    ; security = svc.security
    ; properties = []
    }
  in
  match
    Kafka.Consumer.create
      ~on_ready
      ~on_assigned
      ~on_revoked
      ~on_poll
      ~clock
      consumer_cfg
      ~sw
  with
  | Error e -> Error e
  | Ok consumer ->
    let decode_and_handle raw_msg ~ack =
      match Kafka_service_schema.decode_message topic raw_msg with
      | Error (e, raw_bytes) -> on_decode_error e ~raw_bytes ~ack
      | Ok (msg, trace_ctx) -> handler msg ~ack ~trace_ctx
    in
    let result = Kafka.Consumer.consume consumer ~handler:decode_and_handle () in
    Kafka.Consumer.close consumer;
    result
;;

let consume_partitioned
      svc
      topic
      ~group_id
      ~sw
      ~net
      ~clock
      ?(on_ready = ignore)
      ?(on_assigned = ignore)
      ?(on_revoked = ignore)
      ?(on_poll = ignore)
      ?(on_decode_error = default_on_decode_error)
      ~retry_strategy
      ?(on_retry = fun ~partition:_ ~attempt:_ ~delay_s:_ -> ())
      ?(on_relay_publish = fun ~partition:_ ~attempt:_ ~outcome:_ -> ())
      ?ot
      ~handler
      ()
  =
  let on_decode_error =
    Kafka_service_intf.wrap_on_decode_error
      ~ot
      ~topic_name:(topic_name_to_string topic.name)
      on_decode_error
  in
  match retry_strategy with
  | In_memory retry ->
    let consumer_cfg : Kafka.Consumer.config =
      { brokers = svc.brokers
      ; group_id
      ; topics = [ topic_name_to_string topic.name ]
      ; offset_reset = Kafka.Consumer.Earliest
      ; auto_commit = false
      ; security = svc.security
      ; properties = []
      }
    in
    (match
       Kafka.Consumer.create
         ~on_ready
         ~on_assigned
         ~on_revoked
         ~on_poll
         ~clock
         consumer_cfg
         ~sw
     with
     | Error e -> Error (Consumer_error e)
     | Ok consumer ->
       let decode_and_handle raw_msg ~ack =
         match Kafka_service_schema.decode_message topic raw_msg with
         | Error (e, raw_bytes) ->
           (match on_decode_error e ~raw_bytes ~ack with
            | Kafka.Consumer.Continue -> Kafka.Consumer.Continue
            | Kafka.Consumer.Stop -> Kafka.Consumer.Stop
            | Kafka.Consumer.Error e -> Kafka.Consumer.Error (Kafka_error e))
         | Ok (msg, trace_ctx) -> handler msg ~ack ~trace_ctx
       in
       let result =
         Kafka.Consumer.consume_partitioned
           consumer
           ~sw
           ~clock
           ~retry
           ~on_retry
           ~handler:(fun raw_msg ~ack ->
             match decode_and_handle raw_msg ~ack with
             | Kafka.Consumer.Continue -> Kafka.Consumer.Continue
             | Kafka.Consumer.Stop -> Kafka.Consumer.Stop
             | Kafka.Consumer.Error Retry -> Kafka.Consumer.Error Kafka.Error.Application
             | Kafka.Consumer.Error (Kafka_error e) -> Kafka.Consumer.Error e
             | Kafka.Consumer.Error (Dead_letter reason) ->
               (* FEAT-078: In_memory has no DLQ to route to, so Dead_letter
                  cannot get its own destination the way Retry_topics gives
                  it one. Treating this as an ack-and-drop would violate the
                  acknowledgement ownership invariant (BUG-028) -- "no durable
                  destination -> ack -> gone" is forbidden regardless of
                  which outcome constructor asked for it. Fail closed by
                  running it through the same retry-then-exhaust path as an
                  ordinary handler failure: the message stays unacknowledged
                  either way, and this reuses the existing exhaustion/failure
                  reporting instead of inventing a second one. *)
               Printf.eprintf
                 "sol-worker: DEAD_LETTER without Retry_topics configured (no DLQ \
                  available) reason=%S -- failing closed, not acking\n\
                  %!"
                 reason;
               Kafka.Consumer.Error Kafka.Error.Application)
           ()
         |> Result.map_error (function
           | Kafka.Consumer.Handler_errors errs -> Partition_errors errs
           | Kafka.Consumer.Invalid_config msg ->
             Consumer_error (Kafka.Error.Config_error msg))
       in
       Kafka.Consumer.close consumer;
       result)
  | Retry_topics retry_policy ->
    Kafka_service_retry_topics.consume
      svc
      topic
      ~group_id
      ~sw
      ~net
      ~clock
      ~retry_policy
      ~on_ready
      ~on_assigned
      ~on_revoked
      ~on_poll
      ~on_decode_error
      ~on_retry
      ~on_relay_publish
      ~handler
      ()
;;
