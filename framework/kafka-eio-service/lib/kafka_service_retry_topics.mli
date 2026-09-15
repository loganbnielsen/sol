(** [Retry_topics] strategy backing [Kafka_service.consume_partitioned] — see
    that function's [.mli] doc for the retry/DLQ topic contract. Only [consume]
    is called from [Kafka_service]; the rest is exposed for direct unit testing
    of the retry-routing decision and header codec. *)

(** Typed outcome for a single retry-routing decision. *)
type retry_action =
  | Ack
  | Forward_retry of
      { target : Kafka_service_intf.topic_name
      ; delay_s : float
      }
  | Forward_dlq of { target : Kafka_service_intf.topic_name }

(** Read and validate the [X-Sol-Attempt]/[X-Sol-Retry-At] headers off a message
    forwarded to a retry topic. *)
val parse_retry_metadata : (string * string option) list -> (int * float, string) result

(** BUG-029: backoff (with jitter, capped) for the relay's in-process produce
    retry, keyed by produce attempt number (1-based). Not the user-facing
    retry_policy vocabulary FEAT-078 will introduce -- this only bounds the
    relay's own producer resilience. Exposed for testing the shape of the
    schedule (monotonic growth, cap, non-negativity), not its exact jittered
    value. *)
val produce_backoff_s : int -> float

(** [retry_produce ~max_attempts ~backoff_s ~sleep ~on_retry ~produce ()] retries
    [produce] up to [max_attempts] times, calling [on_retry ~attempt ~error] and
    [sleep (backoff_s attempt)] between attempts. Exposed so the retry-count and
    give-up behavior can be tested with stubbed [produce]/[sleep], without a
    live broker or a real clock (BUG-029). *)
val retry_produce
  :  max_attempts:int
  -> backoff_s:(int -> float)
  -> sleep:(float -> unit)
  -> on_retry:(attempt:int -> error:'e -> unit)
  -> produce:(unit -> (unit, 'e) result)
  -> unit
  -> (unit, 'e) result

val action_of_handler_error
  :  retry_topic:Kafka_service_intf.topic_name
  -> dlq_topic:Kafka_service_intf.topic_name
  -> retry_policy:Kafka.Consumer.retry_policy
  -> attempt:int
  -> Kafka_service_intf.handler_error
  -> (retry_action, Kafka.Error.t) result

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
val retry_message
  :  raw_msg:Kafka.Consumer.message
  -> attempt:int
  -> delay_s:float
  -> relay

(** Retry budget exhausted: a {!retry_message} with [delay_s = 0.0] (dead
    letters are immediate, not scheduled), plus [X-Sol-Origin-Group] (BUG-030:
    dead-lettering is a statement about [group_id]'s processing attempt, not
    an intrinsic property of the source event). *)
val dead_letter_message
  :  raw_msg:Kafka.Consumer.message
  -> attempt:int
  -> group_id:string
  -> relay

(** A retry record that couldn't even be decoded: preserves [raw_msg]'s
    existing headers untouched (this is not another scheduled attempt), and
    appends a decode diagnostic plus [X-Sol-Origin-Group] (BUG-030, see
    {!dead_letter_message}). *)
val retry_decode_failure_message
  :  raw_msg:Kafka.Consumer.message
  -> attempt:int
  -> decode_error:string
  -> group_id:string
  -> relay

(** Execute the side-effecting part of a retry decision: build the relay
    command for the chosen action (for [Forward_retry]/[Forward_dlq]),
    [publish] it, then [ack]. [Ack] skips straight to acking. [group_id] is
    only used on the [Forward_dlq] path (BUG-030's [X-Sol-Origin-Group]). *)
val execute_action
  :  group_id:string
  -> retry_action
  -> raw_msg:Kafka.Consumer.message
  -> attempt:int
  -> publish:
       (target_topic:Kafka_service_intf.topic_name
        -> relay
        -> (unit, Kafka.Error.t) result)
  -> ack:(unit -> (unit, Kafka.Error.t) result)
  -> (unit, Kafka.Error.t) result

(** On a retry-topic decode failure, publish the raw retry record (with decode
    diagnostics attached) to the DLQ rather than reaching the source-path
    [on_decode_error] skip-and-ack contract (BUG-028: that contract would
    ack-drop the last durable copy of the message). Always targets the DLQ, so
    it builds its own relay command rather than going through
    {!execute_action}'s [retry_action] dispatch. *)
val route_retry_decode_error
  :  dlq_topic:Kafka_service_intf.topic_name
  -> raw_msg:Kafka.Consumer.message
  -> attempt:int
  -> decode_error:string
  -> group_id:string
  -> publish:
       (target_topic:Kafka_service_intf.topic_name
        -> relay
        -> (unit, Kafka.Error.t) result)
  -> ack:(unit -> (unit, Kafka.Error.t) result)
  -> (unit, Kafka.Error.t) result

(** The one canonical retry/DLQ topic name: [<source>.<canonical-group>.<suffix>]
    ([suffix] is ["retry"] or ["dlq"]). [group_id] is sanitized to
    alphanumerics and ['-'] and, if long enough to risk Kafka's 249-byte topic
    name limit, truncated with a content-hash suffix (BUG-030: retry/DLQ
    topic identity must include consumer-group identity, or independent
    groups on the same source topic consume each other's retries/dead
    letters). Exposed for direct testing of sanitization, truncation, and
    cross-group distinctness; never reconstruct a retry/DLQ topic name any
    other way. *)
val relay_topic_name : source:string -> group_id:string -> suffix:string -> string

(** [on_relay_publish] fires after each attempt to publish to the retry/DLQ
    topic itself resolves -- [`Published] once (after in-process produce
    retries succeed), [`Failed] once if they're exhausted (BUG-029). Distinct
    from [on_retry], which fires once per record when a retry is *scheduled*,
    before publication is attempted. *)
val consume
  :  Kafka_service_intf.t
  -> 'a Kafka_service_intf.topic
  -> group_id:string
  -> sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> retry_policy:Kafka.Consumer.retry_policy
  -> on_ready:(unit -> unit)
  -> on_decode_error:
       (string
        -> raw_bytes:bytes option
        -> ack:(unit -> (unit, Kafka.Error.t) result)
        -> Kafka.Error.t Kafka.Consumer.handler_result)
  -> on_retry:(partition:int32 -> attempt:int -> delay_s:float -> unit)
  -> on_relay_publish:
       (partition:int32 -> attempt:int -> outcome:[ `Published | `Failed ] -> unit)
  -> handler:
       ('a
        -> ack:(unit -> (unit, Kafka.Error.t) result)
        -> trace_ctx:Obs_trace.t option
        -> Kafka_service_intf.handler_error Kafka.Consumer.handler_result)
  -> unit
  -> (unit, Kafka_service_intf.consume_partitioned_error) result
