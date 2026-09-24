(** E2E integration tests for kafka-eio-service. Requires: rpk redpanda start
    (broker + schema registry on port 8081) Override broker location with the
    standard Kafka broker environment variable. *)

let registry_url =
  match Sys.getenv_opt "SCHEMA_REGISTRY_URL" with
  | Some u -> u
  | None -> "http://localhost:8081"
;;

let admin_url =
  match Sys.getenv_opt "REDPANDA_ADMIN_URL" with
  | Some u -> u
  | None -> "http://localhost:9644"
;;

(* Unique suffix per test run to avoid cross-run topic collisions. *)
let () = Random.self_init ()
let run_id = Random.int 99999

(* ------------------------------------------------------------------ *)
(* Test message modules                                                *)
(* ------------------------------------------------------------------ *)

module PaymentEvent = struct
  type t =
    { payment_id : string
    ; amount_cents : int
    }

  let topic_name =
    Kafka_service.topic_name_exn (Printf.sprintf "sol-svc-payment-%05d" run_id)
  ;;

  let schema =
    {|{
    "type": "object",
    "properties": {
      "payment_id":   { "type": "string"  },
      "amount_cents": { "type": "integer" }
    },
    "required": ["payment_id", "amount_cents"]
  }|}
  ;;

  let encode t =
    `Assoc [ "payment_id", `String t.payment_id; "amount_cents", `Int t.amount_cents ]
  ;;

  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "payment_id" fields, List.assoc_opt "amount_cents" fields with
       | Some (`String pid), Some (`Int ac) -> Ok { payment_id = pid; amount_cents = ac }
       | _ -> Error "missing required fields")
    | _ -> Error "expected object"
  ;;
end

(* Same topic_name as PaymentEvent but changes amount_cents type integer → string.
   This is a breaking change under FULL compatibility. *)
module PaymentEventBreaking = struct
  type t =
    { payment_id : string
    ; amount_cents : string
    }

  let topic_name = PaymentEvent.topic_name

  let schema =
    {|{
    "type": "object",
    "properties": {
      "payment_id":   { "type": "string" },
      "amount_cents": { "type": "string" }
    },
    "required": ["payment_id", "amount_cents"]
  }|}
  ;;

  let encode t =
    `Assoc [ "payment_id", `String t.payment_id; "amount_cents", `String t.amount_cents ]
  ;;

  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "payment_id" fields, List.assoc_opt "amount_cents" fields with
       | Some (`String pid), Some (`String ac) ->
         Ok { payment_id = pid; amount_cents = ac }
       | _ -> Error "missing required fields")
    | _ -> Error "expected object"
  ;;
end

(* Separate topic for the decode error test. *)
module RawTestEvent = struct
  type t = { id : string }

  let topic_name = Kafka_service.topic_name_exn (Printf.sprintf "sol-svc-raw-%05d" run_id)

  let schema =
    {|{
    "type": "object",
    "properties": { "id": { "type": "string" } },
    "required": ["id"]
  }|}
  ;;

  let encode t = `Assoc [ "id", `String t.id ]

  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "id" fields with
       | Some (`String id) -> Ok { id }
       | _ -> Error "missing id")
    | _ -> Error "expected object"
  ;;
end

(* ------------------------------------------------------------------ *)
(* Helpers                                                             *)
(* ------------------------------------------------------------------ *)

let make_config () : Kafka_service.config =
  { brokers = Kafka_test_helpers.brokers ()
  ; schema_registry_url = registry_url
  ; admin_url
  ; linger_ms = 5
  ; partitions = 1
  ; topic_durability = Kafka_service.Broker_default
  ; security = Kafka.Security.default
  }
;;

let test_single_broker_loss_rejects_under_replicated_topic () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let create config =
    match Kafka_service.create config ~sw with
    | Ok service -> service
    | Error e -> Alcotest.fail (Kafka_service.error_to_string e)
  in
  let broker_default = create (make_config ()) in
  (match
     Kafka_service.register
       broker_default
       ~net:env#net
       ~clock:env#clock
       (module RawTestEvent)
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Kafka_service.error_to_string e));
  let durable =
    create { (make_config ()) with topic_durability = Kafka_service.Single_broker_loss }
  in
  match
    Kafka_service.register durable ~net:env#net ~clock:env#clock (module RawTestEvent)
  with
  | Error (Kafka_service.Insufficient_replication { current = 1; required = 3; _ }) -> ()
  | Error e ->
    Alcotest.failf
      "expected insufficient replication, got %s"
      (Kafka_service.error_to_string e)
  | Ok _ -> Alcotest.fail "under-replicated existing topic was accepted"
;;

(* ------------------------------------------------------------------ *)
(* Schema.check tests                                                  *)
(* ------------------------------------------------------------------ *)

(* Schema.check against a topic with no registered schema returns Ok. *)
let test_schema_check_new_topic () =
  Eio_main.run
  @@ fun env ->
  let fresh_id = Random.int 99999 in
  let module Fresh = struct
    type t = unit

    let topic_name =
      Kafka_service.topic_name_exn (Printf.sprintf "sol-svc-fresh-%05d" fresh_id)
    ;;

    let schema = {|{"type":"object","properties":{"x":{"type":"string"}}}|}
    let encode () = `Assoc []
    let decode _ = Ok ()
  end
  in
  match
    Kafka_service.Schema.check ~net:env#net ~clock:env#clock ~registry_url (module Fresh)
  with
  | Error e ->
    Alcotest.failf
      "expected Ok for new topic, got Error: %s"
      (Kafka_service.error_to_string e)
  | Ok () -> ()
;;

(* After registering PaymentEvent, checking the same schema returns Ok. *)
let test_schema_check_compatible () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Alcotest.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match
       Kafka_service.register svc ~net:env#net ~clock:env#clock (module PaymentEvent)
     with
     | Error e -> Alcotest.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok _ ->
       (match
          Kafka_service.Schema.check
            ~net:env#net
            ~clock:env#clock
            ~registry_url
            (module PaymentEvent)
        with
        | Error e ->
          Alcotest.failf
            "compatible schema returned Error: %s"
            (Kafka_service.error_to_string e)
        | Ok () -> ()))
;;

(* After registering PaymentEvent, checking PaymentEventBreaking returns Error. *)
let test_schema_check_incompatible () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Alcotest.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match
       Kafka_service.register svc ~net:env#net ~clock:env#clock (module PaymentEvent)
     with
     | Error e -> Alcotest.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok _ ->
       (match
          Kafka_service.Schema.check
            ~net:env#net
            ~clock:env#clock
            ~registry_url
            (module PaymentEventBreaking)
        with
        | Ok () -> Alcotest.fail "expected Error for incompatible schema, got Ok"
        | Error _ -> ()))
;;

(* Schema.check_all fails fast on first incompatible schema. *)
let test_schema_check_all_fails_fast () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Alcotest.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match
       Kafka_service.register svc ~net:env#net ~clock:env#clock (module PaymentEvent)
     with
     | Error e -> Alcotest.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok _ ->
       (* PaymentEvent is compatible, PaymentEventBreaking is not *)
       let result =
         Kafka_service.Schema.check_all
           ~net:env#net
           ~clock:env#clock
           ~registry_url
           [ (module PaymentEvent : Kafka_service.MESSAGE)
           ; (module PaymentEventBreaking : Kafka_service.MESSAGE)
           ]
       in
       (match result with
        | Ok () -> Alcotest.fail "expected Error for list containing incompatible schema"
        | Error _ -> ()))
;;

(* ------------------------------------------------------------------ *)
(* Produce / consume roundtrip                                         *)
(* ------------------------------------------------------------------ *)

let test_publish_consume_roundtrip () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Alcotest.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match
       Kafka_service.register svc ~net:env#net ~clock:env#clock (module PaymentEvent)
     with
     | Error e -> Alcotest.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok topic ->
       let group_id =
         Printf.sprintf "sol-test-roundtrip-%d-%d" (Unix.getpid ()) (Random.int 9999)
       in
       let received_p, received_r = Eio.Promise.create () in
       let consumer_ready_p, consumer_ready_r = Eio.Promise.create () in
       (* Fork consumer fiber first so it's subscribed before we publish. *)
       Eio.Fiber.fork ~sw (fun () ->
         ignore
           (Kafka_service.consume
              svc
              topic
              ~group_id
              ~sw
              ~clock:env#clock
              ~on_ready:(fun () -> Eio.Promise.resolve consumer_ready_r ())
              ~handler:(fun msg ~ack ~trace_ctx:_ ->
                ignore (ack ());
                Eio.Promise.resolve received_r msg;
                Kafka.Consumer.Stop)
              ()));
       (* Fail fast if the consumer never gets assigned, rather than hanging. *)
       (match
          Eio.Time.with_timeout env#clock 15.0 (fun () ->
            Ok (Eio.Promise.await consumer_ready_p))
        with
        | Error `Timeout ->
          Alcotest.fail "timed out waiting for consumer partition assignment (on_ready)"
        | Ok () -> ());
       let expected = PaymentEvent.{ payment_id = "pay-e2e-001"; amount_cents = 9900 } in
       (match Eio.Promise.await (Kafka_service.publish svc topic expected) with
        | Error e -> Alcotest.failf "publish failed: %s" (Kafka.Error.to_string e)
        | Ok () -> ());
       (* Wait up to 15s for the consumer to receive it. *)
       (match
          Eio.Time.with_timeout env#clock 15.0 (fun () ->
            Ok (Eio.Promise.await received_p))
        with
        | Error `Timeout -> Alcotest.fail "timed out waiting for consumed message"
        | Ok msg ->
          Alcotest.(check string)
            "payment_id"
            expected.payment_id
            msg.PaymentEvent.payment_id;
          Alcotest.(check int)
            "amount_cents"
            expected.amount_cents
            msg.PaymentEvent.amount_cents))
;;

(* ------------------------------------------------------------------ *)
(* consume_partitioned error surfacing                                 *)
(* ------------------------------------------------------------------ *)

module PartitionFailEvent = struct
  type t = { n : int }

  let topic_name =
    Kafka_service.topic_name_exn (Printf.sprintf "sol-svc-partfail-%05d" run_id)
  ;;

  let schema =
    {|{
    "type": "object",
    "properties": { "n": { "type": "integer" } },
    "required": ["n"]
  }|}
  ;;

  let encode t = `Assoc [ "n", `Int t.n ]

  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "n" fields with
       | Some (`Int n) -> Ok { n }
       | _ -> Error "missing n")
    | _ -> Error "expected object"
  ;;
end

(* A handler that always fails, with a retry policy that gives up after one
   attempt, should surface the failing partition's error wrapped in
   Partition_errors — not collapsed into a bare Kafka.Error.t and not
   silently dropped. Regression test for the "consume_partitioned
   re-collapses kafka-eio's per-partition error list" audit finding. *)
let test_consume_partitioned_reports_partition_error () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Alcotest.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match
       Kafka_service.register
         svc
         ~net:env#net
         ~clock:env#clock
         (module PartitionFailEvent)
     with
     | Error e -> Alcotest.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok topic ->
       (match
          Eio.Promise.await (Kafka_service.publish svc topic PartitionFailEvent.{ n = 1 })
        with
        | Error e -> Alcotest.failf "publish failed: %s" (Kafka.Error.to_string e)
        | Ok () -> ());
       let group_id =
         Printf.sprintf "sol-test-partfail-%d-%d" (Unix.getpid ()) (Random.int 9999)
       in
       let retry_strategy =
         Kafka_service.In_memory
           { base_delay_s = 0.0; max_delay_s = 0.0; max_attempts = 1; jitter_ratio = 0.0 }
       in
       let result =
         Eio.Time.with_timeout env#clock 20.0 (fun () ->
           Ok
             (Kafka_service.consume_partitioned
                svc
                topic
                ~group_id
                ~sw
                ~net:env#net
                ~clock:env#clock
                ~retry_strategy
                ~handler:(fun _msg ~ack:_ ~trace_ctx:_ ->
                  Kafka.Consumer.Error Kafka_service.Retry)
                ()))
       in
       (match result with
        | Error `Timeout ->
          Alcotest.fail "timed out waiting for partition to exhaust retries"
        | Ok (Ok ()) -> Alcotest.fail "expected the failing handler to exhaust retries"
        | Ok (Error (Kafka_service.Consumer_error e)) ->
          Alcotest.failf
            "expected Partition_errors, got Consumer_error: %s"
            (Kafka.Error.to_string e)
        | Ok (Error (Kafka_service.Partition_errors errs)) ->
          Alcotest.(check bool) "at least one partition error reported" true (errs <> [])))
;;

(* FEAT-078: In_memory has no DLQ to route Dead_letter to. Acking it anyway
   would be an acknowledge-and-discard with no durable destination, exactly
   the shape BUG-028's invariant forbids. It must fail closed: surfaced as a
   Partition_errors failure (like an exhausted Retry), never silently acked. *)
let test_consume_partitioned_dead_letter_without_retry_topics_fails_closed () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Alcotest.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match
       Kafka_service.register
         svc
         ~net:env#net
         ~clock:env#clock
         (module PartitionFailEvent)
     with
     | Error e -> Alcotest.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok topic ->
       (match
          Eio.Promise.await (Kafka_service.publish svc topic PartitionFailEvent.{ n = 1 })
        with
        | Error e -> Alcotest.failf "publish failed: %s" (Kafka.Error.to_string e)
        | Ok () -> ());
       let group_id =
         Printf.sprintf "sol-test-dlqclosed-%d-%d" (Unix.getpid ()) (Random.int 9999)
       in
       let retry_strategy =
         Kafka_service.In_memory
           { base_delay_s = 0.0; max_delay_s = 0.0; max_attempts = 1; jitter_ratio = 0.0 }
       in
       let result =
         Eio.Time.with_timeout env#clock 20.0 (fun () ->
           Ok
             (Kafka_service.consume_partitioned
                svc
                topic
                ~group_id
                ~sw
                ~net:env#net
                ~clock:env#clock
                ~retry_strategy
                ~handler:(fun _msg ~ack:_ ~trace_ctx:_ ->
                  Kafka.Consumer.Error (Kafka_service.Dead_letter "poison"))
                ()))
       in
       (match result with
        | Error `Timeout ->
          Alcotest.fail "timed out waiting for the dead-lettered partition to fail closed"
        | Ok (Ok ()) ->
          Alcotest.fail
            "Dead_letter under In_memory must not silently succeed (ack-and-drop)"
        | Ok (Error (Kafka_service.Consumer_error e)) ->
          Alcotest.failf
            "expected Partition_errors, got Consumer_error: %s"
            (Kafka.Error.to_string e)
        | Ok (Error (Kafka_service.Partition_errors errs)) ->
          Alcotest.(check bool)
            "dead-letter without a DLQ is reported as a partition failure, not acked"
            true
            (errs <> [])))
;;

(* BUG-043 / FND-0035: a retry relay that stops must fail the worker promptly.
   The handler asks for a retry on the source delivery, so the record goes to the
   retry topic; on the relay's redelivery it returns a Kafka error, which stops
   the relay (it runs with a zero-tolerance policy). The source topic then sits
   idle. Before the fix the relay failure was reported only when the source
   consumer next returned -- never, for an idle healthy source -- so this timed
   out. *)
module RelayDeathEvent = struct
  include PartitionFailEvent

  let topic_name =
    Kafka_service.topic_name_exn (Printf.sprintf "sol-svc-relaydeath-%05d" run_id)
  ;;
end

let test_retry_topics_dead_relay_fails_the_worker () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Alcotest.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match
       Kafka_service.register svc ~net:env#net ~clock:env#clock (module RelayDeathEvent)
     with
     | Error e -> Alcotest.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok topic ->
       (match
          Eio.Promise.await (Kafka_service.publish svc topic RelayDeathEvent.{ n = 1 })
        with
        | Error e -> Alcotest.failf "publish failed: %s" (Kafka.Error.to_string e)
        | Ok () -> ());
       let group_id =
         Printf.sprintf "sol-test-relaydeath-%d-%d" (Unix.getpid ()) (Random.int 9999)
       in
       let retry_strategy =
         Kafka_service.Retry_topics
           { base_delay_s = 0.0; max_delay_s = 0.0; max_attempts = 3; jitter_ratio = 0.0 }
       in
       let deliveries = ref 0 in
       let result =
         Eio.Time.with_timeout env#clock 45.0 (fun () ->
           Ok
             (Kafka_service.consume_partitioned
                svc
                topic
                ~group_id
                ~sw
                ~net:env#net
                ~clock:env#clock
                ~retry_strategy
                ~handler:(fun _msg ~ack:_ ~trace_ctx:_ ->
                  incr deliveries;
                  if !deliveries = 1
                  then Kafka.Consumer.Error Kafka_service.Retry
                  else
                    Kafka.Consumer.Error
                      (Kafka_service.Kafka_error Kafka.Error.Application))
                ()))
       in
       (match result with
        | Error `Timeout ->
          Alcotest.failf
            "the relay stopped (after %d deliveries) but the worker kept running"
            !deliveries
        | Ok (Ok ()) -> Alcotest.fail "a dead relay must not end in Ok ()"
        | Ok (Error _) ->
          Alcotest.(check bool)
            "the relay saw the retried record before it stopped"
            true
            (!deliveries >= 2)))
;;

(* ------------------------------------------------------------------ *)
(* on_decode_error callback                                            *)
(* ------------------------------------------------------------------ *)

(* Fork consumer first, then publish a raw
   (non-wire-format) message. decode_wire will fail on the missing magic byte
   and on_decode_error should be called. *)
let test_decode_error_callback () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Alcotest.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match
       Kafka_service.register svc ~net:env#net ~clock:env#clock (module RawTestEvent)
     with
     | Error e -> Alcotest.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok topic ->
       let group_id =
         Printf.sprintf "sol-test-decode-err-%d-%d" (Unix.getpid ()) (Random.int 9999)
       in
       let error_stream = Eio.Stream.create 1 in
       let consumer_ready_p, consumer_ready_r = Eio.Promise.create () in
       (* Fork consumer so it's subscribed before the bad message arrives. *)
       Eio.Fiber.fork ~sw (fun () ->
         ignore
           (Kafka_service.consume
              svc
              topic
              ~group_id
              ~sw
              ~clock:env#clock
              ~on_ready:(fun () -> Eio.Promise.resolve consumer_ready_r ())
              ~on_decode_error:(fun e ~raw_bytes:_ ~ack ->
                Eio.Stream.add error_stream e;
                ignore (ack ());
                Kafka.Consumer.Stop)
              ~handler:(fun _msg ~ack ~trace_ctx:_ ->
                ignore (ack ());
                Kafka.Consumer.Stop)
              ()));
       (* Wait until the broker has assigned partitions before publishing. *)
       (match
          Eio.Time.with_timeout env#clock 15.0 (fun () ->
            Ok (Eio.Promise.await consumer_ready_p))
        with
        | Error `Timeout ->
          Alcotest.fail "timed out waiting for consumer partition assignment (on_ready)"
        | Ok () -> ());
       (* Publish raw bytes (no Confluent wire framing) via the raw producer. *)
       let producer_cfg : Kafka.Producer.config =
         { brokers = Kafka_test_helpers.brokers ()
         ; delivery_mode = Kafka.Producer.At_least_once
         ; linger_ms = None
         ; security = Kafka.Security.default
         ; properties = []
         }
       in
       (match Kafka.Producer.create producer_cfg ~sw with
        | Error e ->
          Alcotest.failf "raw producer create failed: %s" (Kafka.Error.to_string e)
        | Ok producer ->
          let raw = Bytes.of_string {|{"id":"raw-no-wire-format"}|} in
          (match
             Eio.Promise.await
               (Kafka.Producer.produce_await
                  producer
                  ~topic:(Kafka_service.topic_name_to_string RawTestEvent.topic_name)
                  ~value:(Some raw)
                  ())
           with
           | Error e -> Alcotest.failf "raw publish failed: %s" (Kafka.Error.to_string e)
           | Ok () -> ());
          Kafka.Producer.close producer);
       (* Wait up to 10s for the decode error to be observed. *)
       (match
          Eio.Time.with_timeout env#clock 10.0 (fun () ->
            Ok (Eio.Stream.take error_stream))
        with
        | Error `Timeout -> Alcotest.fail "timed out waiting for decode error callback"
        | Ok _ -> ()))
;;

(* ------------------------------------------------------------------ *)
(* Runner                                                              *)
(* ------------------------------------------------------------------ *)

let () =
  let open Alcotest in
  run
    "kafka_service_integration"
    [ ( "schema_check"
      , [ test_case "new topic returns ok" `Slow test_schema_check_new_topic
        ; test_case "compatible schema returns ok" `Slow test_schema_check_compatible
        ; test_case
            "incompatible schema returns error"
            `Slow
            test_schema_check_incompatible
        ; test_case "check_all fails fast" `Slow test_schema_check_all_fails_fast
        ] )
    ; ( "roundtrip"
      , [ test_case "publish and consume" `Slow test_publish_consume_roundtrip ] )
    ; ( "durability"
      , [ test_case
            "under-replicated existing topic is rejected"
            `Slow
            test_single_broker_loss_rejects_under_replicated_topic
        ] )
    ; ( "consume_partitioned"
      , [ test_case
            "reports partition error, not a collapsed single error"
            `Slow
            test_consume_partitioned_reports_partition_error
        ; test_case
            "dead-letter without Retry_topics fails closed, not acked"
            `Slow
            test_consume_partitioned_dead_letter_without_retry_topics_fails_closed
        ; test_case
            "a stopped Retry_topics relay fails the worker promptly"
            `Slow
            test_retry_topics_dead_relay_fails_the_worker
        ] )
    ; ( "error_handling"
      , [ test_case
            "on_decode_error fires for non-wire-format message"
            `Slow
            test_decode_error_callback
        ] )
    ]
;;
