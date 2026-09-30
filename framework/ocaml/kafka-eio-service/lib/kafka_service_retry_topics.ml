let message_rng = Random.State.make_self_init ()
let message_rng_mutex = Mutex.create ()

let message_backoff_s (policy : Kafka.Consumer.retry_policy) attempt =
  Mutex.lock message_rng_mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock message_rng_mutex)
    (fun () -> Kafka.Consumer.backoff_s ~rng:message_rng policy attempt)
;;

let hdr_attempt = "X-Sol-Attempt"
let hdr_retry_at = "X-Sol-Retry-At"
let hdr_decode_error = "X-Sol-Decode-Error"
let hdr_origin_group = "X-Sol-Origin-Group"
let produce_max_attempts = 5
let produce_base_delay_s = 0.1
let produce_max_delay_s = 5.0
let produce_jitter_ratio = 0.2
let produce_rng = Random.State.make_self_init ()
let produce_rng_mutex = Mutex.create ()

let produce_backoff_s attempt =
  let raw = produce_base_delay_s *. (2. ** Float.of_int (attempt - 1)) in
  let jitter_unit =
    Mutex.lock produce_rng_mutex;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock produce_rng_mutex)
      (fun () -> Random.State.float produce_rng (2.0 *. produce_jitter_ratio))
  in
  let jittered = raw *. (1.0 +. (jitter_unit -. produce_jitter_ratio)) in
  Float.min produce_max_delay_s (Float.max 0.0 jittered)
;;

let retry_produce ~max_attempts ~backoff_s ~sleep ~on_retry ~produce () =
  let rec go attempt =
    match produce () with
    | Ok () -> Ok ()
    | Error e when attempt >= max_attempts -> Error e
    | Error e ->
      on_retry ~attempt ~error:e;
      sleep (backoff_s attempt);
      go (attempt + 1)
  in
  go 1
;;

let parse_int_hdr key headers =
  match Option.join (List.assoc_opt key headers) with
  | None -> Error (Printf.sprintf "missing %s" key)
  | Some s ->
    (match int_of_string_opt s with
     | Some n when n >= 1 -> Ok n
     | _ -> Error (Printf.sprintf "malformed %s: %S" key s))
;;

let parse_float_hdr key headers =
  match Option.join (List.assoc_opt key headers) with
  | None -> Error (Printf.sprintf "missing %s" key)
  | Some s ->
    (match float_of_string_opt s with
     | Some n when classify_float n <> FP_nan && classify_float n <> FP_infinite -> Ok n
     | _ -> Error (Printf.sprintf "malformed %s: %S" key s))
;;

let parse_retry_metadata headers =
  let open Result.Syntax in
  let* attempt = parse_int_hdr hdr_attempt headers in
  let* retry_at = parse_float_hdr hdr_retry_at headers in
  Ok (attempt, retry_at)
;;

let strip_sol_hdrs headers =
  List.filter (fun (k, _) -> k <> hdr_attempt && k <> hdr_retry_at) headers
;;

type relay =
  { source : Kafka.Consumer.message
  ; headers : (string * string option) list
  ; attempt : int
  ; delay_s : float
  }

let retry_message ~raw_msg ~attempt ~delay_s =
  let retry_at = Unix.gettimeofday () +. delay_s in
  let headers =
    (hdr_attempt, Some (string_of_int attempt))
    :: (hdr_retry_at, Some (string_of_float retry_at))
    :: strip_sol_hdrs raw_msg.Kafka.Consumer.headers
  in
  { source = raw_msg; headers; attempt; delay_s }
;;

let dead_letter_message ~raw_msg ~attempt ~group_id =
  let base = retry_message ~raw_msg ~attempt ~delay_s:0.0 in
  { base with headers = (hdr_origin_group, Some group_id) :: base.headers }
;;

let decode_failure_message ~raw_msg ~attempt ~decode_error ~group_id =
  { source = raw_msg
  ; headers =
      (hdr_decode_error, Some decode_error)
      :: (hdr_origin_group, Some group_id)
      :: raw_msg.Kafka.Consumer.headers
  ; attempt
  ; delay_s = 0.0
  }
;;

type retry_action =
  | Ack
  | Forward_retry of
      { target : Kafka_service_intf.topic_name
      ; delay_s : float
      }
  | Forward_dlq of { target : Kafka_service_intf.topic_name }

let topic_name_to_string = Kafka_service_intf.topic_name_to_string

let decide_action
      ~retry_topic
      ~dlq_topic
      ~(retry_policy : Kafka.Consumer.retry_policy)
      ~attempt
  =
  if attempt >= retry_policy.max_attempts
  then Forward_dlq { target = dlq_topic }
  else
    Forward_retry
      { target = retry_topic; delay_s = message_backoff_s retry_policy attempt }
;;

let action_of_handler_error ~retry_topic ~dlq_topic ~retry_policy ~attempt = function
  | Kafka_service_intf.Kafka_error e -> Error e
  | Kafka_service_intf.Retry ->
    Ok (decide_action ~retry_topic ~dlq_topic ~retry_policy ~attempt)
  | Kafka_service_intf.Dead_letter _ -> Ok (Forward_dlq { target = dlq_topic })
;;

let execute_action ~group_id action ~raw_msg ~attempt ~publish ~ack =
  let open Result.Syntax in
  match action with
  | Ack -> ack ()
  | Forward_retry { target; delay_s } ->
    let* () = publish ~target_topic:target (retry_message ~raw_msg ~attempt ~delay_s) in
    ack ()
  | Forward_dlq { target } ->
    let* () =
      publish ~target_topic:target (dead_letter_message ~raw_msg ~attempt ~group_id)
    in
    ack ()
;;

let route_decode_error
      ~stage
      ~dlq_topic
      ~raw_msg
      ~attempt
      ~decode_error
      ~group_id
      ~publish
      ~ack
  =
  Printf.eprintf
    "sol-worker: %s to_dlq=true error=%S\n%!"
    (match stage with
     | `Source -> "DECODE_ERROR"
     | `Retry -> "RETRY_DECODE_ERROR")
    decode_error;
  let open Result.Syntax in
  let* () =
    publish
      ~target_topic:dlq_topic
      (decode_failure_message ~raw_msg ~attempt ~decode_error ~group_id)
  in
  ack ()
;;

let max_group_segment_len = 64
let group_hash_len = 12

let sanitize_group_id group_id =
  let sanitized =
    String.map
      (function
        | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-') as c -> c
        | _ -> '-')
      group_id
  in
  if sanitized = "" then "unscoped" else sanitized
;;

let canonical_group_segment group_id =
  let readable = sanitize_group_id group_id in
  let hash = String.sub (Digest.to_hex (Digest.string group_id)) 0 group_hash_len in
  let prefix_len = max_group_segment_len - group_hash_len - 1 in
  let prefix =
    if String.length readable <= prefix_len
    then readable
    else String.sub readable 0 prefix_len
  in
  prefix ^ "-" ^ hash
;;

let relay_topic_name ~source ~group_id ~suffix =
  Printf.sprintf "%s.%s.%s" source (canonical_group_segment group_id) suffix
;;

type record_stage =
  | Source
  | Retry of int

let process_handler_result
      ~stage
      ~retry_topic
      ~dlq_topic
      ~retry_policy
      ~group_id
      ~raw_msg
      ~publish
      ~ack
  = function
  | Kafka.Consumer.Continue -> Kafka.Consumer.Continue
  | Kafka.Consumer.Stop -> Kafka.Consumer.Stop
  | Kafka.Consumer.Error handler_error ->
    let attempt =
      match stage, handler_error with
      | Source, _ -> 1
      | Retry attempt, Kafka_service_intf.Retry -> attempt + 1
      | ( Retry attempt
        , (Kafka_service_intf.Dead_letter _ | Kafka_service_intf.Kafka_error _) ) ->
        attempt
    in
    (match handler_error with
     | Kafka_service_intf.Dead_letter reason ->
       Printf.eprintf "sol-worker: DEAD_LETTER reason=%S\n%!" reason
     | Kafka_service_intf.Retry | Kafka_service_intf.Kafka_error _ -> ());
    (match
       action_of_handler_error
         ~retry_topic
         ~dlq_topic
         ~retry_policy
         ~attempt
         handler_error
     with
     | Error e -> Kafka.Consumer.Error e
     | Ok action ->
       (match execute_action ~group_id action ~raw_msg ~attempt ~publish ~ack with
        | Ok () -> Kafka.Consumer.Continue
        | Error e -> Kafka.Consumer.Error e))
;;

type 'a runtime =
  { group_id : string
  ; retry_policy : Kafka.Consumer.retry_policy
  ; consumer_properties : (string * string) list
  ; hooks : Kafka_service_intf.consumer_hooks
  ; decode_error_policy : Kafka_service_intf.decode_error_policy
  ; observe_decode_error :
      string
      -> raw_bytes:bytes option
      -> disposition:[ `Dropped | `Dead_lettered ]
      -> unit
  ; handler :
      'a
      -> ack:(unit -> (unit, Kafka.Error.t) result)
      -> trace_ctx:Obs_trace.t option
      -> Kafka_service_intf.handler_error Kafka.Consumer.handler_result
  }

let prepare_topics
      (svc : Kafka_service_intf.t)
      (topic : 'a Kafka_service_intf.topic)
      ~net
      ~clock
      ~group_id
      ~(retry_policy : Kafka.Consumer.retry_policy)
  =
  let open Result.Syntax in
  let config_error msg =
    Kafka_service_intf.Consumer_error (Kafka.Error.Config_error msg)
  in
  let* () =
    if retry_policy.max_attempts < 1
    then Error (config_error "Retry_topics retry_policy.max_attempts must be >= 1")
    else Ok ()
  in
  let source = topic_name_to_string topic.name in
  let* retry_topic_name =
    Kafka_service_intf.topic_name (relay_topic_name ~source ~group_id ~suffix:"retry")
    |> Result.map_error config_error
  in
  let* dlq_topic_name =
    Kafka_service_intf.topic_name (relay_topic_name ~source ~group_id ~suffix:"dlq")
    |> Result.map_error config_error
  in
  let verify_existing topic_name =
    match
      Kafka_service_intf.query_topic_partitions
        net
        ~clock
        ~admin_url:svc.admin_url
        ~topic_name:(topic_name_to_string topic_name)
    with
    | Error e ->
      Error (config_error (Kafka_service_intf.topic_partition_error_to_string e))
    | Ok Kafka_service_intf.Topic_not_found -> Ok ()
    | Ok metadata
      when Kafka_service_intf.topic_has_required_replication svc.topic_durability metadata
      -> Ok ()
    | Ok (Kafka_service_intf.Topic_partitions { replication_factor; _ }) ->
      Error
        (config_error
           (Printf.sprintf
              "topic '%s' has replication factor %d; 3 is required for \
               single-broker-loss durability"
              (topic_name_to_string topic_name)
              replication_factor))
  in
  let* () = verify_existing retry_topic_name in
  let* () =
    Kafka_service_intf.ensure_topic
      svc.producer
      ~topic_name:(topic_name_to_string retry_topic_name)
      ~partitions:svc.partitions
      ~topic_durability:svc.topic_durability
    |> Result.map_error (fun e -> Kafka_service_intf.Consumer_error e)
  in
  let* () = verify_existing dlq_topic_name in
  let* () =
    Kafka_service_intf.ensure_topic
      svc.producer
      ~topic_name:(topic_name_to_string dlq_topic_name)
      ~partitions:svc.partitions
      ~topic_durability:svc.topic_durability
    |> Result.map_error (fun e -> Kafka_service_intf.Consumer_error e)
  in
  Ok (retry_topic_name, dlq_topic_name)
;;

let publish_relay (svc : Kafka_service_intf.t) ~clock (runtime : _ runtime) =
  let { Kafka_service_intf.on_relay_publish; kafka = { Kafka.Consumer.on_retry; _ } } =
    runtime.hooks
  in
  let publish ~target_topic (msg : relay) =
    let partition = msg.source.Kafka.Consumer.partition in
    on_retry ~partition ~attempt:msg.attempt ~delay_s:msg.delay_s;
    let result =
      retry_produce
        ~max_attempts:produce_max_attempts
        ~backoff_s:produce_backoff_s
        ~sleep:(Eio.Time.sleep clock)
        ~on_retry:(fun ~attempt:produce_attempt ~error:e ->
          Printf.eprintf
            "warn: kafka_service: PUBLISH_RETRY target=%s attempt=%d produce_attempt=%d \
             error=%s\n\
             %!"
            (topic_name_to_string target_topic)
            msg.attempt
            produce_attempt
            (Kafka.Error.to_string e))
        ~produce:(fun () ->
          Eio.Promise.await
            (Kafka.Producer.produce_await
               svc.producer
               ~topic:(topic_name_to_string target_topic)
               ~value:msg.source.Kafka.Consumer.value
               ?key:msg.source.Kafka.Consumer.key
               ~headers:msg.headers
               ()))
        ()
    in
    (match result with
     | Error e ->
       Printf.eprintf
         "error: kafka_service: PUBLISH_FAILED target=%s attempt=%d produce_attempts=%d \
          error=%s -- exhausted in-process produce retries, not acking\n\
          %!"
         (topic_name_to_string target_topic)
         msg.attempt
         produce_max_attempts
         (Kafka.Error.to_string e);
       on_relay_publish ~partition ~attempt:msg.attempt ~outcome:`Failed
     | Ok () -> on_relay_publish ~partition ~attempt:msg.attempt ~outcome:`Published);
    result
  in
  publish
;;

let run_consumers
      (svc : Kafka_service_intf.t)
      (topic : 'a Kafka_service_intf.topic)
      ~sw
      ~clock
      runtime
      ~retry_topic_name
      ~dlq_topic_name
      ~publish
  =
  let open Result.Syntax in
  let { group_id
      ; retry_policy
      ; consumer_properties
      ; hooks = { kafka = kafka_hooks; _ }
      ; decode_error_policy
      ; observe_decode_error
      ; handler
      }
    =
    runtime
  in
  let consumer_cfg : Kafka.Consumer.config =
    { brokers = svc.brokers
    ; group_id
    ; topics = [ topic_name_to_string topic.name ]
    ; offset_reset = Kafka.Consumer.Earliest
    ; auto_commit = false
    ; security = svc.security
    ; properties = consumer_properties
    }
  in
  let no_retry : Kafka.Consumer.retry_policy =
    { base_delay_s = 0.0; max_delay_s = 0.0; max_attempts = 0; jitter_ratio = 0.0 }
  in
  let relay_failure : Kafka_service_intf.consume_partitioned_error option ref =
    ref None
  in
  let relay_closed_source = ref false in
  match Kafka.Consumer.create ~hooks:kafka_hooks ~clock consumer_cfg ~sw with
  | Error e -> Error (Kafka_service_intf.Consumer_error e)
  | Ok consumer ->
    let retry_consumer_cfg : Kafka.Consumer.config =
      { brokers = svc.brokers
      ; group_id = group_id ^ "-sol-retry"
      ; topics = [ topic_name_to_string retry_topic_name ]
      ; offset_reset = Kafka.Consumer.Earliest
      ; auto_commit = false
      ; security = svc.security
      ; properties = consumer_properties
      }
    in
    let start_retry_relay () =
      match Kafka.Consumer.create ~clock retry_consumer_cfg ~sw with
      | Error e ->
        Kafka.Consumer.close consumer;
        Error (Kafka_service_intf.Consumer_error e)
      | Ok retry_consumer ->
        let decode_retry raw_msg ~ack ~attempt =
          match Kafka_service_schema.decode_message topic raw_msg with
          | Error (e, raw_bytes) ->
            ignore raw_bytes;
            (match
               route_decode_error
                 ~stage:`Retry
                 ~dlq_topic:dlq_topic_name
                 ~raw_msg
                 ~attempt
                 ~decode_error:e
                 ~group_id
                 ~publish
                 ~ack
             with
             | Ok () -> Kafka.Consumer.Continue
             | Error e -> Kafka.Consumer.Error e)
          | Ok (msg, trace_ctx) ->
            process_handler_result
              ~stage:(Retry attempt)
              ~retry_topic:retry_topic_name
              ~dlq_topic:dlq_topic_name
              ~retry_policy
              ~group_id
              ~raw_msg
              ~publish
              ~ack
              (handler msg ~ack ~trace_ctx)
        in
        let retry_handler raw_msg ~ack =
          match parse_retry_metadata raw_msg.Kafka.Consumer.headers with
          | Error e ->
            Printf.eprintf "warn: kafka_service: retry metadata: %s\n%!" e;
            let action = Forward_dlq { target = dlq_topic_name } in
            (match
               execute_action
                 ~group_id
                 action
                 ~raw_msg
                 ~attempt:(max 1 retry_policy.max_attempts)
                 ~publish
                 ~ack
             with
             | Ok () -> Kafka.Consumer.Continue
             | Error e -> Kafka.Consumer.Error e)
          | Ok (attempt, retry_at) ->
            let delay = max 0.0 (retry_at -. Unix.gettimeofday ()) in
            if delay > 0.001 then Eio.Time.sleep clock delay;
            decode_retry raw_msg ~ack ~attempt
        in
        let stop_source_after_relay_failure () =
          relay_closed_source := true;
          Printf.eprintf
            "error: kafka_service: RETRY_RELAY_STOPPED -- stopping the source consumer \
             so the worker fails instead of running without retry delivery\n\
             %!";
          Kafka.Consumer.close consumer
        in
        Eio.Fiber.fork ~sw (fun () ->
          (try
             match
               Kafka.Consumer.consume_partitioned
                 retry_consumer
                 ~sw
                 ~clock
                 ~retry:no_retry
                 ~hooks:
                   { Kafka.Consumer.default_hooks with
                     on_retry = (fun ~partition:_ ~attempt:_ ~delay_s:_ -> ())
                   }
                 ~handler:retry_handler
                 ()
             with
             | Ok () -> ()
             | Error (Kafka.Consumer.Handler_errors errs) ->
               List.iter
                 (fun (partition, e) ->
                    Printf.eprintf
                      "error: kafka_service: RETRY_RELAY_STOPPED partition=%ld error=%s \
                       -- retry delivery for this partition has stopped (BUG-029)\n\
                       %!"
                      partition
                      (Kafka.Error.to_string e))
                 errs;
               relay_failure := Some (Kafka_service_intf.Partition_errors errs);
               stop_source_after_relay_failure ()
             | Error (Kafka.Consumer.Invalid_config msg) ->
               Printf.eprintf
                 "error: kafka_service: RETRY_RELAY_STOPPED config=%s -- retry delivery \
                  has stopped (BUG-029)\n\
                  %!"
                 msg;
               relay_failure
               := Some (Kafka_service_intf.Consumer_error (Kafka.Error.Config_error msg));
               stop_source_after_relay_failure ()
           with
           | Eio.Cancel.Cancelled _ -> ());
          Kafka.Consumer.close retry_consumer);
        Ok ()
    in
    let* () = start_retry_relay () in
    let decode_and_handle raw_msg ~ack =
      match Kafka_service_schema.decode_message topic raw_msg with
      | Error (e, raw_bytes) ->
        (match (decode_error_policy : Kafka_service_intf.decode_error_policy) with
         | Ack_and_drop ->
           observe_decode_error e ~raw_bytes ~disposition:`Dropped;
           Kafka_service_intf.ack_and_drop_decode_error e ~raw_bytes ~ack
         | Route_to_dlq ->
           observe_decode_error e ~raw_bytes ~disposition:`Dead_lettered;
           (match
              route_decode_error
                ~stage:`Source
                ~dlq_topic:dlq_topic_name
                ~raw_msg
                ~attempt:1
                ~decode_error:e
                ~group_id
                ~publish
                ~ack
            with
            | Ok () -> Kafka.Consumer.Continue
            | Error e -> Kafka.Consumer.Error e))
      | Ok (msg, trace_ctx) ->
        process_handler_result
          ~stage:Source
          ~retry_topic:retry_topic_name
          ~dlq_topic:dlq_topic_name
          ~retry_policy
          ~group_id
          ~raw_msg
          ~publish
          ~ack
          (handler msg ~ack ~trace_ctx)
    in
    let run_source () =
      Kafka.Consumer.consume_partitioned
        consumer
        ~sw
        ~clock
        ~retry:no_retry
        ~hooks:
          { Kafka.Consumer.default_hooks with
            on_retry = (fun ~partition:_ ~attempt:_ ~delay_s:_ -> ())
          }
        ~handler:decode_and_handle
        ()
      |> Result.map_error (function
        | Kafka.Consumer.Handler_errors errs -> Kafka_service_intf.Partition_errors errs
        | Kafka.Consumer.Invalid_config msg ->
          Kafka_service_intf.Consumer_error (Kafka.Error.Config_error msg))
    in
    let reconcile_relay result =
      match result, !relay_failure with
      | Error _, Some relay_err when !relay_closed_source ->
        Printf.eprintf
          "error: kafka_service: failing -- the retry relay stopped and closed the \
           source consumer (BUG-043)\n\
           %!";
        Error relay_err
      | Ok (), Some relay_err ->
        Printf.eprintf
          "error: kafka_service: failing -- the retry relay stopped earlier and never \
           recovered (BUG-029)\n\
           %!";
        Error relay_err
      | (Ok () | Error _), _ -> result
    in
    let result = run_source () |> reconcile_relay in
    Kafka.Consumer.close consumer;
    result
;;

let consume svc topic ~sw ~net ~clock runtime () =
  let open Result.Syntax in
  let* retry_topic_name, dlq_topic_name =
    prepare_topics
      svc
      topic
      ~net
      ~clock
      ~group_id:runtime.group_id
      ~retry_policy:runtime.retry_policy
  in
  let publish = publish_relay svc ~clock runtime in
  run_consumers svc topic ~sw ~clock runtime ~retry_topic_name ~dlq_topic_name ~publish
;;
