let backoff_s n = Float.min (1.0 *. (2. ** Float.of_int n)) 600.0
let hdr_attempt = "X-Sol-Attempt"
let hdr_retry_at = "X-Sol-Retry-At"

let parse_int_hdr key headers =
  match Option.join (List.assoc_opt key headers) with
  | None -> Error (Printf.sprintf "missing %s" key)
  | Some s -> (
      match int_of_string_opt s with
      | Some n when n >= 1 -> Ok n
      | _ -> Error (Printf.sprintf "malformed %s: %S" key s))

let parse_float_hdr key headers =
  match Option.join (List.assoc_opt key headers) with
  | None -> Error (Printf.sprintf "missing %s" key)
  | Some s -> (
      match float_of_string_opt s with
      | Some n
        when classify_float n <> FP_nan && classify_float n <> FP_infinite ->
          Ok n
      | _ -> Error (Printf.sprintf "malformed %s: %S" key s))

let parse_retry_metadata headers =
  match parse_int_hdr hdr_attempt headers with
  | Error e -> Error e
  | Ok attempt -> (
      match parse_float_hdr hdr_retry_at headers with
      | Error e -> Error e
      | Ok retry_at -> Ok (attempt, retry_at))

let strip_sol_hdrs headers =
  List.filter (fun (k, _) -> k <> hdr_attempt && k <> hdr_retry_at) headers

(** Typed outcome for a single retry-routing decision. *)
type retry_action =
  | Ack
  | Forward_retry of { target : Kafka_service_intf.topic_name; delay_s : float }
  | Forward_dlq of { target : Kafka_service_intf.topic_name }

let topic_name_to_string = Kafka_service_intf.topic_name_to_string

(** Decide where a failed message should go after [attempt] attempts. [attempt]
    is the attempt number that will be committed to the target topic (i.e. the
    already-incremented counter). *)
let decide_action ~retry_topic ~dlq_topic ~max_attempts ~attempt =
  if attempt >= max_attempts then Forward_dlq { target = dlq_topic }
  else Forward_retry { target = retry_topic; delay_s = backoff_s attempt }

(** Execute the side-effecting part of a retry action: publish then ack. *)
let execute_action action ~raw_msg ~attempt ~publish_raw ~ack =
  match action with
  | Ack -> ack ()
  | Forward_retry { target; delay_s } -> (
      match
        publish_raw ~target_topic:target ~attempt
          ~raw_bytes:raw_msg.Kafka.Consumer.value
          ~headers:raw_msg.Kafka.Consumer.headers ~delay_s
          ~partition:raw_msg.Kafka.Consumer.partition
      with
      | Ok () -> ack ()
      | Error e -> Error e)
  | Forward_dlq { target } -> (
      match
        publish_raw ~target_topic:target ~attempt
          ~raw_bytes:raw_msg.Kafka.Consumer.value
          ~headers:raw_msg.Kafka.Consumer.headers ~delay_s:0.0
          ~partition:raw_msg.Kafka.Consumer.partition
      with
      | Ok () -> ack ()
      | Error e -> Error e)

let consume (svc : Kafka_service_intf.t) (topic : 'a Kafka_service_intf.topic)
    ~group_id ~sw ~clock ~max_attempts ~on_ready ~on_decode_error ~on_retry
    ~handler () =
  let ( let* ) = Result.bind in
  let config_error msg =
    Kafka_service_intf.Consumer_error (Kafka.Error.Config_error msg)
  in
  let* () =
    if max_attempts < 1 then
      Error (config_error "Retry_topics max_attempts must be >= 1")
    else Ok ()
  in
  let* retry_topic_name =
    Kafka_service_intf.topic_name (topic_name_to_string topic.name ^ "-retry")
    |> Result.map_error config_error
  in
  let* dlq_topic_name =
    Kafka_service_intf.topic_name (topic_name_to_string topic.name ^ "-dlq")
    |> Result.map_error config_error
  in
  let* () =
    Kafka_service_intf.ensure_topic svc.producer
      ~topic_name:(topic_name_to_string retry_topic_name)
      ~partitions:svc.partitions
    |> Result.map_error (fun e -> Kafka_service_intf.Consumer_error e)
  in
  let* () =
    Kafka_service_intf.ensure_topic svc.producer
      ~topic_name:(topic_name_to_string dlq_topic_name)
      ~partitions:svc.partitions
    |> Result.map_error (fun e -> Kafka_service_intf.Consumer_error e)
  in
  let publish_raw ~target_topic ~attempt ~raw_bytes ~headers ~delay_s ~partition
      =
    on_retry ~partition ~attempt ~delay_s;
    let retry_at = Unix.gettimeofday () +. delay_s in
    let new_headers =
      (hdr_attempt, Some (string_of_int attempt))
      :: (hdr_retry_at, Some (string_of_float retry_at))
      :: strip_sol_hdrs headers
    in
    match
      Eio.Promise.await
        (Kafka.Producer.produce_await svc.producer
           ~topic:(topic_name_to_string target_topic)
           ~value:raw_bytes ~headers:new_headers ())
    with
    | Ok () -> Ok ()
    | Error e ->
        Printf.eprintf
          "sol-worker: PUBLISH_FAILED target=%s attempt=%d error=%s — not acking\n\
           %!"
          (topic_name_to_string target_topic)
          attempt (Kafka.Error.to_string e);
        Error e
  in
  let consumer_cfg : Kafka.Consumer.config =
    {
      brokers = svc.brokers;
      group_id;
      topics = [ topic_name_to_string topic.name ];
      offset_reset = Kafka.Consumer.Earliest;
      auto_commit = false;
      security = svc.security;
      properties = [];
    }
  in
  match Kafka.Consumer.create ~on_ready ~clock consumer_cfg ~sw with
  | Error e -> Error (Kafka_service_intf.Consumer_error e)
  | Ok consumer ->
      let retry_consumer_cfg : Kafka.Consumer.config =
        {
          brokers = svc.brokers;
          group_id = group_id ^ "-sol-retry";
          topics = [ topic_name_to_string retry_topic_name ];
          offset_reset = Kafka.Consumer.Earliest;
          auto_commit = false;
          security = svc.security;
          properties = [];
        }
      in
      let* () =
        match Kafka.Consumer.create ~clock retry_consumer_cfg ~sw with
        | Error e ->
            Kafka.Consumer.close consumer;
            Error (Kafka_service_intf.Consumer_error e)
        | Ok retry_consumer ->
            let decode_retry raw_msg ~ack ~attempt =
              match Kafka_service_schema.decode_message topic raw_msg with
              | Error (e, raw_bytes) -> on_decode_error e ~raw_bytes ~ack
              | Ok (msg, trace_ctx) -> (
                  match handler msg ~ack ~trace_ctx with
                  | Kafka.Consumer.Continue -> Kafka.Consumer.Continue
                  | Kafka.Consumer.Stop -> Kafka.Consumer.Stop
                  | Kafka.Consumer.Error _ -> (
                      let next = attempt + 1 in
                      let action =
                        decide_action ~retry_topic:retry_topic_name
                          ~dlq_topic:dlq_topic_name ~max_attempts ~attempt:next
                      in
                      match
                        execute_action action ~raw_msg ~attempt:next
                          ~publish_raw ~ack
                      with
                      | Ok () -> Kafka.Consumer.Continue
                      | Error e -> Kafka.Consumer.Error e))
            in
            Eio.Fiber.fork ~sw (fun () ->
                let rec loop () =
                  match Kafka.Consumer.fetch retry_consumer with
                  | Error Kafka.Error.Destroy -> ()
                  | Error e ->
                      Printf.eprintf
                        "warn: kafka_service: retry consumer fetch: %s\n%!"
                        (Kafka.Error.to_string e)
                  | Ok raw_msg -> (
                      let acked = ref false in
                      let ack () =
                        if not !acked then begin
                          acked := true;
                          Kafka.Consumer.commit retry_consumer raw_msg
                        end
                        else Ok ()
                      in
                      match
                        parse_retry_metadata raw_msg.Kafka.Consumer.headers
                      with
                      | Error e -> (
                          Printf.eprintf
                            "warn: kafka_service: retry metadata: %s\n%!" e;
                          let action =
                            Forward_dlq { target = dlq_topic_name }
                          in
                          match
                            execute_action action ~raw_msg
                              ~attempt:(max 1 max_attempts) ~publish_raw ~ack
                          with
                          | Ok () -> loop ()
                          | Error _ -> ())
                      | Ok (attempt, retry_at) -> (
                          let delay =
                            max 0.0 (retry_at -. Unix.gettimeofday ())
                          in
                          (* ponytail: kafka-eio 0.1 hid Kafka_raw, so this loop can no longer
                   librdkafka-pause the partition during the backoff sleep; the retry
                   stream's bounded capacity still caps how far ahead librdkafka can
                   prefetch. Revisit if that prefetch overhead matters. *)
                          if delay > 0.001 then Eio.Time.sleep clock delay;
                          match decode_retry raw_msg ~ack ~attempt with
                          | Kafka.Consumer.Stop -> ()
                          | Kafka.Consumer.Continue -> loop ()
                          | Kafka.Consumer.Error _ -> ()))
                in
                (try loop () with Eio.Cancel.Cancelled _ -> ());
                Kafka.Consumer.close retry_consumer);
            Ok ()
      in
      let decode_and_handle raw_msg ~ack =
        match Kafka_service_schema.decode_message topic raw_msg with
        | Error (e, raw_bytes) -> on_decode_error e ~raw_bytes ~ack
        | Ok (msg, trace_ctx) -> (
            match handler msg ~ack ~trace_ctx with
            | Kafka.Consumer.Continue -> Kafka.Consumer.Continue
            | Kafka.Consumer.Stop -> Kafka.Consumer.Stop
            | Kafka.Consumer.Error _ -> (
                let action =
                  decide_action ~retry_topic:retry_topic_name
                    ~dlq_topic:dlq_topic_name ~max_attempts ~attempt:1
                in
                match
                  execute_action action ~raw_msg ~attempt:1 ~publish_raw ~ack
                with
                | Ok () -> Kafka.Consumer.Continue
                | Error e -> Kafka.Consumer.Error e))
      in
      let no_retry : Kafka.Consumer.retry_policy =
        { base_delay_s = 0.0; max_delay_s = 0.0; max_attempts = 0 }
      in
      let result =
        Kafka.Consumer.consume_partitioned consumer ~sw ~clock ~retry:no_retry
          ~on_retry:(fun ~partition:_ ~attempt:_ ~delay_s:_ -> ())
          ~handler:decode_and_handle ()
        |> Result.map_error (function
          | Kafka.Consumer.Handler_errors errs ->
              Kafka_service_intf.Partition_errors errs
          | Kafka.Consumer.Invalid_config msg ->
              Kafka_service_intf.Consumer_error (Kafka.Error.Config_error msg))
      in
      Kafka.Consumer.close consumer;
      result
