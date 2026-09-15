let backoff_s n = Float.min (1.0 *. (2. ** Float.of_int n)) 600.0
let hdr_attempt = "X-Sol-Attempt"
let hdr_retry_at = "X-Sol-Retry-At"
let hdr_decode_error = "X-Sol-Decode-Error"
let hdr_origin_group = "X-Sol-Origin-Group"

(* BUG-029: bounded in-process retry for the relay's own producer calls
   (retry/DLQ publication), so a single transient produce failure self-heals
   instead of immediately exhausting consume_partitioned's zero-tolerance
   policy below. These are internal constants, not the user-facing
   retry_policy vocabulary FEAT-078 will introduce -- this only protects the
   relay's plumbing, not application-level retry semantics. *)
let produce_max_attempts = 5
let produce_base_delay_s = 0.1
let produce_max_delay_s = 5.0
let produce_jitter_ratio = 0.2

(* Scoped to this module, not process-wide like Obs_trace's rng_state, but
   mutex-protected for the same reason: Random.State.t mutation is not
   domain-safe, and this state is shared across every partition fiber's
   publish calls. Never the global Random module (this repo has been
   bitten twice by that). *)
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

(** [retry_produce ~max_attempts ~backoff_s ~sleep ~on_retry ~produce ()] retries
    [produce] (a single attempt, side-effecting) up to [max_attempts] times,
    calling [on_retry ~attempt ~error] and [sleep (backoff_s attempt)] between
    attempts. [produce]/[sleep]/[on_retry] are injected so this is testable
    without a live broker or a real clock. Exposed for testing (BUG-029). *)
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
  match parse_int_hdr hdr_attempt headers with
  | Error e -> Error e
  | Ok attempt ->
    (match parse_float_hdr hdr_retry_at headers with
     | Error e -> Error e
     | Ok retry_at -> Ok (attempt, retry_at))
;;

let strip_sol_hdrs headers =
  List.filter (fun (k, _) -> k <> hdr_attempt && k <> hdr_retry_at) headers
;;

(** A relay command: publish [source] to some target topic, carrying the
    already-fully-resolved [headers] to send (no further header policy is
    decided at publish time) plus [attempt]/[delay_s] for metrics
    ([on_retry]/[on_relay_publish]) — not for serialization. Built exclusively
    by [retry_message]/[dead_letter_message]/[retry_decode_failure_message]
    below; nothing else should construct one by hand. *)
type relay =
  { source : Kafka.Consumer.message
  ; headers : (string * string option) list
  ; attempt : int
  ; delay_s : float
  }

(** A scheduled retry: strips any stale [X-Sol-*] headers from [raw_msg] and
    stamps fresh [X-Sol-Attempt]/[X-Sol-Retry-At] ([delay_s] from now). *)
let retry_message ~raw_msg ~attempt ~delay_s =
  let retry_at = Unix.gettimeofday () +. delay_s in
  let headers =
    (hdr_attempt, Some (string_of_int attempt))
    :: (hdr_retry_at, Some (string_of_float retry_at))
    :: strip_sol_hdrs raw_msg.Kafka.Consumer.headers
  in
  { source = raw_msg; headers; attempt; delay_s }
;;

(** Retry budget exhausted: a [retry_message] with [delay_s = 0.0] (dead
    letters are immediate, not scheduled), plus [X-Sol-Origin-Group] (BUG-030:
    dead-lettering is a statement about [group_id]'s processing attempt, not
    an intrinsic property of the source event -- the DLQ topic is already
    scoped to [group_id], but the header keeps the record self-describing if
    it's ever exported or inspected independently of its topic name). *)
let dead_letter_message ~raw_msg ~attempt ~group_id =
  let base = retry_message ~raw_msg ~attempt ~delay_s:0.0 in
  { base with headers = (hdr_origin_group, Some group_id) :: base.headers }
;;

(** A retry record that couldn't even be decoded: preserves [raw_msg]'s
    existing headers untouched (including whatever [X-Sol-Attempt]/
    [X-Sol-Retry-At] it already carried — this is not another scheduled
    attempt), and appends a decode diagnostic plus [X-Sol-Origin-Group]
    (BUG-030, see {!dead_letter_message}). *)
let retry_decode_failure_message ~raw_msg ~attempt ~decode_error ~group_id =
  { source = raw_msg
  ; headers =
      (hdr_decode_error, Some decode_error)
      :: (hdr_origin_group, Some group_id)
      :: raw_msg.Kafka.Consumer.headers
  ; attempt
  ; delay_s = 0.0
  }
;;

(** Typed outcome for a single retry-routing decision. *)
type retry_action =
  | Ack
  | Forward_retry of
      { target : Kafka_service_intf.topic_name
      ; delay_s : float
      }
  | Forward_dlq of { target : Kafka_service_intf.topic_name }

let topic_name_to_string = Kafka_service_intf.topic_name_to_string

(** Decide where a failed message should go after [attempt] attempts. [attempt]
    is the attempt number that will be committed to the target topic (i.e. the
    already-incremented counter). *)
let decide_action ~retry_topic ~dlq_topic ~max_attempts ~attempt =
  if attempt >= max_attempts
  then Forward_dlq { target = dlq_topic }
  else Forward_retry { target = retry_topic; delay_s = backoff_s attempt }
;;

let action_of_handler_error ~retry_topic ~dlq_topic ~max_attempts ~attempt = function
  | Kafka_service_intf.Kafka_error e -> Error e
  | Kafka_service_intf.Retry ->
    Ok (decide_action ~retry_topic ~dlq_topic ~max_attempts ~attempt)
  | Kafka_service_intf.Dead_letter _ -> Ok (Forward_dlq { target = dlq_topic })
;;

(** Execute the side-effecting part of a retry action: build the relay
    command, publish it, then ack. [raw_msg]'s key travels with it (via
    [relay.source]), so a retried message hashes to the same partition on the
    target topic that its key would hash to on the source topic (BUG-027:
    both topics share [svc.partitions]). *)
let execute_action ~group_id action ~raw_msg ~attempt ~publish ~ack =
  match action with
  | Ack -> ack ()
  | Forward_retry { target; delay_s } ->
    (match publish ~target_topic:target (retry_message ~raw_msg ~attempt ~delay_s) with
     | Ok () -> ack ()
     | Error e -> Error e)
  | Forward_dlq { target } ->
    (match
       publish ~target_topic:target (dead_letter_message ~raw_msg ~attempt ~group_id)
     with
     | Ok () -> ack ()
     | Error e -> Error e)
;;

(** A retry record that couldn't even be decoded always goes to the DLQ; it
    doesn't need [execute_action]'s [retry_action] dispatch, so it builds its
    own relay command and publishes directly. *)
let route_retry_decode_error
      ~dlq_topic
      ~raw_msg
      ~attempt
      ~decode_error
      ~group_id
      ~publish
      ~ack
  =
  Printf.eprintf "sol-worker: RETRY_DECODE_ERROR to_dlq=true error=%S\n%!" decode_error;
  match
    publish
      ~target_topic:dlq_topic
      (retry_decode_failure_message ~raw_msg ~attempt ~decode_error ~group_id)
  with
  | Ok () -> ack ()
  | Error e -> Error e
;;

(* BUG-030: retry/DLQ topic identity must include both source-topic and
   consumer-group identity, or independent consumer groups on the same source
   topic can consume each other's retries/dead-letters. Group ids are
   sanitized to alphanumerics and '-' only -- never left free to contain '.'
   or '_', which Kafka's own metrics/JMX naming treats as interchangeable, so
   two differently-punctuated group ids could otherwise collide at the
   metrics layer even while remaining distinct topic-name strings. Kafka
   topic names cap at 249 bytes; a group id long enough to risk that limit is
   truncated and given a short content-hash suffix, always (not only when a
   collision is detected -- there is no registry of every other group id to
   check against, so "would collide" is read conservatively as "truncation
   happened at all"), so two different overlong ids can never truncate to the
   same canonical segment. *)
let max_group_segment_len = 64

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
  let sanitized = sanitize_group_id group_id in
  if String.length sanitized <= max_group_segment_len
  then sanitized
  else (
    let hash_suffix = String.sub (Digest.to_hex (Digest.string group_id)) 0 8 in
    let prefix_len = max_group_segment_len - String.length hash_suffix - 1 in
    String.sub sanitized 0 prefix_len ^ "-" ^ hash_suffix)
;;

(** The one canonical retry/DLQ topic name: [<source>.<canonical-group>.<suffix>]
    ([suffix] is ["retry"] or ["dlq"]). Used by topic provisioning and the
    retry consumer alike -- never reconstruct a retry/DLQ topic name any other
    way (BUG-030). *)
let relay_topic_name ~source ~group_id ~suffix =
  Printf.sprintf "%s.%s.%s" source (canonical_group_segment group_id) suffix
;;

let consume
      (svc : Kafka_service_intf.t)
      (topic : 'a Kafka_service_intf.topic)
      ~group_id
      ~sw
      ~clock
      ~max_attempts
      ~on_ready
      ~on_decode_error
      ~on_retry
      ~on_relay_publish
      ~handler
      ()
  =
  let ( let* ) = Result.bind in
  let config_error msg =
    Kafka_service_intf.Consumer_error (Kafka.Error.Config_error msg)
  in
  let* () =
    if max_attempts < 1
    then Error (config_error "Retry_topics max_attempts must be >= 1")
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
  let* () =
    Kafka_service_intf.ensure_topic
      svc.producer
      ~topic_name:(topic_name_to_string retry_topic_name)
      ~partitions:svc.partitions
    |> Result.map_error (fun e -> Kafka_service_intf.Consumer_error e)
  in
  let* () =
    Kafka_service_intf.ensure_topic
      svc.producer
      ~topic_name:(topic_name_to_string dlq_topic_name)
      ~partitions:svc.partitions
    |> Result.map_error (fun e -> Kafka_service_intf.Consumer_error e)
  in
  (* The relay's headers are already fully resolved by whichever smart
     constructor built [msg] -- this function knows nothing about retry vs.
     decode-failure header policy, only how to publish a relay command. *)
  let publish ~target_topic (msg : relay) =
    let partition = msg.source.Kafka.Consumer.partition in
    on_retry ~partition ~attempt:msg.attempt ~delay_s:msg.delay_s;
    (* BUG-029: bounded retry around the produce call itself -- a single
       transient failure here must not be the thing that reaches
       consume_partitioned's exhaustion policy below. *)
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
  let no_retry : Kafka.Consumer.retry_policy =
    { base_delay_s = 0.0; max_delay_s = 0.0; max_attempts = 0 }
  in
  (* BUG-029: the relay (retry-topic consumer) forks off and previously had no
     way to make its own failure visible to this function's return value --
     it would log to stderr and the source consumer would keep running,
     looking healthy, while retry delivery was silently dead. Set from the
     forked relay fiber below; read once the source consumer stops, so a
     relay failure is never reported as an overall Ok result. Plain [ref] is
     safe here: both readers/writers are Eio fibers on the same domain, never
     OS threads, so there is no data race to guard against. *)
  let relay_failure : Kafka_service_intf.consume_partitioned_error option ref =
    ref None
  in
  match Kafka.Consumer.create ~on_ready ~clock consumer_cfg ~sw with
  | Error e -> Error (Kafka_service_intf.Consumer_error e)
  | Ok consumer ->
    let retry_consumer_cfg : Kafka.Consumer.config =
      { brokers = svc.brokers
      ; group_id = group_id ^ "-sol-retry"
      ; topics = [ topic_name_to_string retry_topic_name ]
      ; offset_reset = Kafka.Consumer.Earliest
      ; auto_commit = false
      ; security = svc.security
      ; properties = []
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
          | Error (e, raw_bytes) ->
            ignore raw_bytes;
            (match
               route_retry_decode_error
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
            (match handler msg ~ack ~trace_ctx with
             | Kafka.Consumer.Continue -> Kafka.Consumer.Continue
             | Kafka.Consumer.Stop -> Kafka.Consumer.Stop
             | Kafka.Consumer.Error handler_error ->
               let next =
                 match handler_error with
                 | Kafka_service_intf.Retry -> attempt + 1
                 | Kafka_service_intf.Dead_letter reason ->
                   Printf.eprintf "sol-worker: DEAD_LETTER reason=%S\n%!" reason;
                   attempt
                 | Kafka_service_intf.Kafka_error _ -> attempt
               in
               (match
                  action_of_handler_error
                    ~retry_topic:retry_topic_name
                    ~dlq_topic:dlq_topic_name
                    ~max_attempts
                    ~attempt:next
                    handler_error
                with
                | Error e -> Kafka.Consumer.Error e
                | Ok action ->
                  (match
                     execute_action ~group_id action ~raw_msg ~attempt:next ~publish ~ack
                   with
                   | Ok () -> Kafka.Consumer.Continue
                   | Error e -> Kafka.Consumer.Error e)))
        in
        (* BUG-027: routed through [consume_partitioned] (same as the source
           topic below), not a single serial fetch loop -- so the per-message
           backoff sleep below blocks only its own partition. During the sleep
           [consume_partitioned] pauses that partition at the librdkafka level,
           matching the isolation [In_memory] already documents. *)
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
                 ~attempt:(max 1 max_attempts)
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
        Eio.Fiber.fork ~sw (fun () ->
          (try
             match
               Kafka.Consumer.consume_partitioned
                 retry_consumer
                 ~sw
                 ~clock
                 ~retry:no_retry
                 ~on_retry:(fun ~partition:_ ~attempt:_ ~delay_s:_ -> ())
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
               relay_failure := Some (Kafka_service_intf.Partition_errors errs)
             | Error (Kafka.Consumer.Invalid_config msg) ->
               Printf.eprintf
                 "error: kafka_service: RETRY_RELAY_STOPPED config=%s -- retry delivery \
                  has stopped (BUG-029)\n\
                  %!"
                 msg;
               relay_failure
               := Some (Kafka_service_intf.Consumer_error (Kafka.Error.Config_error msg))
           with
           | Eio.Cancel.Cancelled _ -> ());
          Kafka.Consumer.close retry_consumer);
        Ok ()
    in
    let decode_and_handle raw_msg ~ack =
      match Kafka_service_schema.decode_message topic raw_msg with
      | Error (e, raw_bytes) ->
        (match on_decode_error e ~raw_bytes ~ack with
         | Kafka.Consumer.Continue -> Kafka.Consumer.Continue
         | Kafka.Consumer.Stop -> Kafka.Consumer.Stop
         | Kafka.Consumer.Error e -> Kafka.Consumer.Error e)
      | Ok (msg, trace_ctx) ->
        (match handler msg ~ack ~trace_ctx with
         | Kafka.Consumer.Continue -> Kafka.Consumer.Continue
         | Kafka.Consumer.Stop -> Kafka.Consumer.Stop
         | Kafka.Consumer.Error handler_error ->
           (match handler_error with
            | Kafka_service_intf.Dead_letter reason ->
              Printf.eprintf "sol-worker: DEAD_LETTER reason=%S\n%!" reason
            | Kafka_service_intf.Retry | Kafka_service_intf.Kafka_error _ -> ());
           (match
              action_of_handler_error
                ~retry_topic:retry_topic_name
                ~dlq_topic:dlq_topic_name
                ~max_attempts
                ~attempt:1
                handler_error
            with
            | Error e -> Kafka.Consumer.Error e
            | Ok action ->
              (match
                 execute_action ~group_id action ~raw_msg ~attempt:1 ~publish ~ack
               with
               | Ok () -> Kafka.Consumer.Continue
               | Error e -> Kafka.Consumer.Error e)))
    in
    let result =
      Kafka.Consumer.consume_partitioned
        consumer
        ~sw
        ~clock
        ~retry:no_retry
        ~on_retry:(fun ~partition:_ ~attempt:_ ~delay_s:_ -> ())
        ~handler:decode_and_handle
        ()
      |> Result.map_error (function
        | Kafka.Consumer.Handler_errors errs -> Kafka_service_intf.Partition_errors errs
        | Kafka.Consumer.Invalid_config msg ->
          Kafka_service_intf.Consumer_error (Kafka.Error.Config_error msg))
    in
    (* BUG-029: an already-failed source consumer keeps its own error; a
       healthy-looking source result must not mask an earlier relay failure
       -- that is exactly the silent-degradation shape this ticket exists to
       close. This is the documented exhaustion policy: a stopped retry
       relay fails the worker rather than leaving it running degraded. *)
    let result =
      match result, !relay_failure with
      | Ok (), Some relay_err ->
        Printf.eprintf
          "error: kafka_service: failing -- the retry relay stopped earlier and never \
           recovered (BUG-029)\n\
           %!";
        Error relay_err
      | (Ok () | Error _), _ -> result
    in
    Kafka.Consumer.close consumer;
    result
;;
