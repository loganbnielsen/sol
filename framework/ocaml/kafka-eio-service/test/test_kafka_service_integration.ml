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

let () = Random.self_init ()
let run_id = Random.int 99999

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

  let partitions = 3
  let key t = Some t.payment_id

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

  let partitions = 3
  let key t = Some t.payment_id

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

  let partitions = 1
  let key t = Some t.id
  let encode t = `Assoc [ "id", `String t.id ]

  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "id" fields with
       | Some (`String id) -> Ok { id }
       | _ -> Error "missing id")
    | _ -> Error "expected object"
  ;;
end

let make_config () : Kafka_service.config =
  { brokers = Kafka_test_helpers.brokers ()
  ; schema_registry_url = registry_url
  ; admin_url
  ; linger_ms = 5
  ; topic_durability = Kafka_service.Broker_default
  ; security = Kafka.Security.default
  }
;;

let register (type a) svc ~net ~clock (module M : Kafka_service.MESSAGE with type t = a) =
  let open Result.Syntax in
  let* _id =
    Kafka_service.Schema.register
      ~net
      ~clock
      ~registry_url:(make_config ()).schema_registry_url
      (module M)
  in
  Kafka_service.register svc ~net ~clock (module M)
;;

let test_single_broker_loss_rejects_under_replicated_topic () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let create config =
    match Kafka_service.create config ~sw with
    | Ok service -> service
    | Error e -> Windtrap.fail (Kafka_service.error_to_string e)
  in
  let broker_default = create (make_config ()) in
  (match register broker_default ~net:env#net ~clock:env#clock (module RawTestEvent) with
   | Ok _ -> ()
   | Error e -> Windtrap.fail (Kafka_service.error_to_string e));
  let durable =
    create { (make_config ()) with topic_durability = Kafka_service.Single_broker_loss }
  in
  match register durable ~net:env#net ~clock:env#clock (module RawTestEvent) with
  | Error (Kafka_service.Insufficient_replication { current = 1; required = 3; _ }) -> ()
  | Error e ->
    Windtrap.failf
      "expected insufficient replication, got %s"
      (Kafka_service.error_to_string e)
  | Ok _ -> Windtrap.fail "under-replicated existing topic was accepted"
;;

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
    let partitions = 1
    let key () = None
    let encode () = `Assoc []
    let decode _ = Ok ()
  end
  in
  match
    Kafka_service.Schema.check ~net:env#net ~clock:env#clock ~registry_url (module Fresh)
  with
  | Error e ->
    Windtrap.failf
      "expected Ok for new topic, got Error: %s"
      (Kafka_service.error_to_string e)
  | Ok () -> ()
;;

let test_schema_check_compatible () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Windtrap.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match register svc ~net:env#net ~clock:env#clock (module PaymentEvent) with
     | Error e -> Windtrap.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok _ ->
       (match
          Kafka_service.Schema.check
            ~net:env#net
            ~clock:env#clock
            ~registry_url
            (module PaymentEvent)
        with
        | Error e ->
          Windtrap.failf
            "compatible schema returned Error: %s"
            (Kafka_service.error_to_string e)
        | Ok () -> ()))
;;

let test_schema_check_incompatible () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Windtrap.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match register svc ~net:env#net ~clock:env#clock (module PaymentEvent) with
     | Error e -> Windtrap.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok _ ->
       (match
          Kafka_service.Schema.check
            ~net:env#net
            ~clock:env#clock
            ~registry_url
            (module PaymentEventBreaking)
        with
        | Ok () -> Windtrap.fail "expected Error for incompatible schema, got Ok"
        | Error _ -> ()))
;;

let test_schema_check_all_fails_fast () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Windtrap.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match register svc ~net:env#net ~clock:env#clock (module PaymentEvent) with
     | Error e -> Windtrap.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok _ ->
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
        | Ok () -> Windtrap.fail "expected Error for list containing incompatible schema"
        | Error _ -> ()))
;;

let test_publish_consume_roundtrip () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Windtrap.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match register svc ~net:env#net ~clock:env#clock (module PaymentEvent) with
     | Error e -> Windtrap.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok topic ->
       let group_id =
         Printf.sprintf "sol-test-roundtrip-%d-%d" (Unix.getpid ()) (Random.int 9999)
       in
       let received_p, received_r = Eio.Promise.create () in
       let consumer_ready_p, consumer_ready_r = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         ignore
           (Kafka_service.consume
              svc
              topic
              ~group_id
              ~sw
              ~clock:env#clock
              ~hooks:
                { Kafka.Consumer.default_hooks with
                  on_ready = (fun () -> Eio.Promise.resolve consumer_ready_r ())
                }
              ~handler:(fun msg ~ack ~trace_ctx:_ ->
                ignore (ack ());
                Eio.Promise.resolve received_r msg;
                Kafka.Consumer.Stop)
              ()));
       (match
          Eio.Time.with_timeout env#clock 15.0 (fun () ->
            Ok (Eio.Promise.await consumer_ready_p))
        with
        | Error `Timeout ->
          Windtrap.fail "timed out waiting for consumer partition assignment (on_ready)"
        | Ok () -> ());
       let expected = PaymentEvent.{ payment_id = "pay-e2e-001"; amount_cents = 9900 } in
       (match Eio.Promise.await (Kafka_service.publish svc topic expected) with
        | Error e -> Windtrap.failf "publish failed: %s" (Kafka.Error.to_string e)
        | Ok () -> ());
       (match
          Eio.Time.with_timeout env#clock 15.0 (fun () ->
            Ok (Eio.Promise.await received_p))
        with
        | Error `Timeout -> Windtrap.fail "timed out waiting for consumed message"
        | Ok msg ->
          Windtrap.equal
            Windtrap.string
            ~msg:"payment_id"
            expected.payment_id
            msg.PaymentEvent.payment_id;
          Windtrap.equal
            Windtrap.int
            ~msg:"amount_cents"
            expected.amount_cents
            msg.PaymentEvent.amount_cents))
;;

module IdleTopic = struct
  type t = unit

  let topic_name =
    Kafka_service.topic_name_exn (Printf.sprintf "sol-svc-idle-%05d" run_id)
  ;;

  let schema = {|{"type":"object","properties":{"x":{"type":"string"}}}|}
  let partitions = 1
  let key () = None
  let encode () = `Assoc []
  let decode _ = Ok ()
end

let test_consume_returns_promptly_when_idle_and_stop_resolves () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Windtrap.fail (Kafka_service.error_to_string e)
  | Ok svc ->
    (match register svc ~net:env#net ~clock:env#clock (module IdleTopic) with
     | Error e -> Windtrap.fail (Kafka_service.error_to_string e)
     | Ok topic ->
       let stop_p, stop_r = Eio.Promise.create () in
       let done_p, done_r = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         Eio.Promise.resolve
           done_r
           (Kafka_service.consume
              svc
              topic
              ~group_id:(Printf.sprintf "sol-svc-idle-%05d" run_id)
              ~sw
              ~clock:env#clock
              ~stop:stop_p
              ~handler:(fun () ~ack:_ ~trace_ctx:_ -> Kafka.Consumer.Continue)
              ()));
       Eio.Time.sleep env#clock 1.0;
       Windtrap.equal
         Windtrap.bool
         ~msg:"nothing to consume, so the loop is still parked on the topic"
         true
         (not (Eio.Promise.is_resolved done_p));
       Eio.Promise.resolve stop_r ();
       (match
          Eio.Time.with_timeout_exn env#clock 5.0 (fun () -> Eio.Promise.await done_p)
        with
        | Ok () -> ()
        | Error e -> Windtrap.fail (Kafka.Error.to_string e)))
;;

let test_schema_check_wrong_registry_path_is_an_error () =
  Eio_main.run
  @@ fun env ->
  match
    Kafka_service.Schema.check
      ~net:env#net
      ~clock:env#clock
      ~registry_url:(registry_url ^ "/not-the-registry")
      (module PaymentEvent)
  with
  | Ok () -> Windtrap.fail "a 404 that is not 'subject not found' must not pass the gate"
  | Error _ -> ()
;;

module StubRegistryEvent = struct
  include RawTestEvent

  let topic_name =
    Kafka_service.topic_name_exn (Printf.sprintf "sol-svc-stubreg-%05d" run_id)
  ;;
end

let serve_stub_registry ~sw ~net ~log =
  let socket =
    Eio.Net.listen
      ~sw
      ~backlog:8
      ~reuse_addr:true
      net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio.Net.run_server socket ~on_error:ignore (fun flow _ ->
      let buf = Eio.Buf_read.of_flow flow ~max_size:1_000_000 in
      let request_line = Eio.Buf_read.line buf in
      let rec headers len =
        match Eio.Buf_read.line buf with
        | "" -> len
        | h ->
          let lower = String.lowercase_ascii h in
          let len =
            if String.starts_with ~prefix:"content-length:" lower
            then int_of_string (String.trim (String.sub h 15 (String.length h - 15)))
            else len
          in
          headers len
      in
      let len = headers 0 in
      if len > 0 then ignore (Eio.Buf_read.take len buf);
      log := request_line :: !log;
      let status, body =
        if String.starts_with ~prefix:"PUT /config/" request_line
        then "500 Internal Server Error", {|{"error_code":50001,"message":"boom"}|}
        else if String.starts_with ~prefix:"POST /compatibility/" request_line
        then "200 OK", {|{"is_compatible":true}|}
        else if
          String.starts_with ~prefix:"POST /subjects/" request_line
          && String.ends_with ~suffix:"/versions" request_line
        then "201 Created", {|{"id":1}|}
        else "200 OK", {|{"id":1}|}
      in
      Eio.Flow.copy_string
        (Printf.sprintf
           "HTTP/1.1 %s\r\n\
            content-type: application/json\r\n\
            content-length: %d\r\n\
            connection: close\r\n\
            \r\n\
            %s"
           status
           (String.length body)
           body)
        flow));
  match Eio.Net.listening_addr socket with
  | `Tcp (_, port) -> Printf.sprintf "http://127.0.0.1:%d" port
  | _ -> Windtrap.fail "stub registry has no port"
;;

let test_contract_register_sets_full_before_registering_and_fails_loudly () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let log = ref [] in
  let stub_url = serve_stub_registry ~sw ~net:env#net ~log in
  (match
     Kafka_service.Schema.register
       ~net:env#net
       ~clock:env#clock
       ~registry_url:stub_url
       (module StubRegistryEvent)
   with
   | Ok _ -> Windtrap.fail "a failed compatibility PUT must fail contract registration"
   | Error (Kafka_service.Schema_registry _) -> ()
   | Error e ->
     Windtrap.failf "expected Schema_registry, got %s" (Kafka_service.error_to_string e));
  let requests = List.rev !log in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the compatibility PUT was attempted"
    true
    (List.exists (String.starts_with ~prefix:"PUT /config/") requests);
  Windtrap.equal
    Windtrap.bool
    ~msg:
      (Printf.sprintf
         "no schema version was registered after the failed PUT (%s)"
         (String.concat " | " requests))
    false
    (List.exists
       (fun r ->
          String.starts_with ~prefix:"POST /subjects/" r
          && String.ends_with ~suffix:"/versions" r)
       requests)
;;

let test_runtime_register_never_writes_the_registry () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let log = ref [] in
  let stub_url = serve_stub_registry ~sw ~net:env#net ~log in
  let config = { (make_config ()) with schema_registry_url = stub_url } in
  (match Kafka_service.create config ~sw with
   | Error e -> Windtrap.failf "create failed: %s" (Kafka_service.error_to_string e)
   | Ok svc ->
     (match
        Kafka_service.register
          svc
          ~net:env#net
          ~clock:env#clock
          (module StubRegistryEvent)
      with
      | Ok _ -> ()
      | Error e -> Windtrap.failf "register failed: %s" (Kafka_service.error_to_string e)));
  let requests = List.rev !log in
  Windtrap.equal
    Windtrap.bool
    ~msg:
      (Printf.sprintf
         "runtime register issued no compatibility PUT (%s)"
         (String.concat " | " requests))
    false
    (List.exists (String.starts_with ~prefix:"PUT /config/") requests);
  Windtrap.equal
    Windtrap.bool
    ~msg:
      (Printf.sprintf
         "runtime register issued no schema version POST (%s)"
         (String.concat " | " requests))
    false
    (List.exists
       (fun r ->
          String.starts_with ~prefix:"POST /subjects/" r
          && String.ends_with ~suffix:"/versions" r)
       requests)
;;

let produce_undecodable ~sw ~topic_name =
  let producer_cfg : Kafka.Producer.config =
    { brokers = Kafka_test_helpers.brokers ()
    ; delivery_mode = Kafka.Producer.At_least_once
    ; linger_ms = None
    ; security = Kafka.Security.default
    ; properties = []
    }
  in
  match Kafka.Producer.create producer_cfg ~sw with
  | Error e -> Windtrap.failf "raw producer create failed: %s" (Kafka.Error.to_string e)
  | Ok producer ->
    (match
       Eio.Promise.await
         (Kafka.Producer.produce_receipt
            producer
            ~topic:(Kafka_service.topic_name_to_string topic_name)
            ~value:(Some (Bytes.of_string "not-wire-format"))
            ~key:(Bytes.of_string "order-7")
            ~headers:[ "app-header", Some "kept" ]
            ())
     with
     | Error e -> Windtrap.failf "raw publish failed: %s" (Kafka.Error.to_string e)
     | Ok () -> ());
    Kafka.Producer.close producer
;;

let read_first ~sw ~clock ~topic ~timeout_s =
  let cfg : Kafka.Consumer.config =
    { brokers = Kafka_test_helpers.brokers ()
    ; group_id =
        Printf.sprintf "sol-test-dlq-reader-%d-%d" (Unix.getpid ()) (Random.int 99999)
    ; topics = [ topic ]
    ; offset_reset = Kafka.Consumer.Earliest
    ; auto_commit = false
    ; security = Kafka.Security.default
    ; properties = []
    }
  in
  match Kafka.Consumer.create ~clock cfg ~sw with
  | Error e -> Windtrap.failf "dlq reader create failed: %s" (Kafka.Error.to_string e)
  | Ok consumer ->
    let seen = ref None in
    (match
       Eio.Time.with_timeout clock timeout_s (fun () ->
         Ok
           (Kafka.Consumer.consume
              consumer
              ~handler:(fun msg ~ack:_ ->
                seen := Some msg;
                Kafka.Consumer.Stop)
              ()))
     with
     | Ok _ | Error `Timeout -> ());
    Kafka.Consumer.close consumer;
    !seen
;;

exception Test_done

let while_consuming ~consume f =
  let result = ref None in
  (try
     Eio.Switch.run (fun isw ->
       Eio.Fiber.fork ~sw:isw (fun () -> consume ~sw:isw);
       result := Some (f ());
       Eio.Switch.fail isw Test_done)
   with
   | Test_done -> ());
  Option.get !result
;;

let with_registered (type a) (module M : Kafka_service.MESSAGE with type t = a) f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Windtrap.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match register svc ~net:env#net ~clock:env#clock (module M) with
     | Error e -> Windtrap.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok topic -> f env sw svc topic)
;;

module Decode_policy_event (N : sig
    val suffix : string
  end) =
struct
  type t = { id : string }

  let topic_name =
    Kafka_service.topic_name_exn (Printf.sprintf "sol-svc-decode-%s-%05d" N.suffix run_id)
  ;;

  let schema = RawTestEvent.schema
  let partitions = 1
  let key t = Some t.id
  let encode t = `Assoc [ "id", `String t.id ]

  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "id" fields with
       | Some (`String id) -> Ok { id }
       | _ -> Error "missing id")
    | _ -> Error "expected object"
  ;;
end

module Drop_event = Decode_policy_event (struct
    let suffix = "drop"
  end)

let test_an_unacked_record_is_redelivered_to_the_same_group () =
  with_registered
    (module RawTestEvent)
    (fun env _sw svc topic ->
       let group_id =
         Printf.sprintf "sol-test-unacked-%d-%d" (Unix.getpid ()) (Random.int 9999)
       in
       (match
          Eio.Promise.await
            (Kafka_service.publish svc topic RawTestEvent.{ id = "must-redeliver" })
        with
        | Error e -> Windtrap.failf "publish failed: %s" (Kafka.Error.to_string e)
        | Ok () -> ());
       let stopped_on, stopped_on_r = Eio.Promise.create () in
       while_consuming
         ~consume:(fun ~sw ->
           ignore
             (Kafka_service.consume
                svc
                topic
                ~group_id
                ~sw
                ~clock:env#clock
                ~handler:(fun (_ : RawTestEvent.t) ~ack:_ ~trace_ctx:_ ->
                  ignore (Eio.Promise.try_resolve stopped_on_r ());
                  Kafka.Consumer.Stop)
                ()))
         (fun () ->
            match
              Eio.Time.with_timeout env#clock 30.0 (fun () ->
                Ok (Eio.Promise.await stopped_on))
            with
            | Error `Timeout -> Windtrap.fail "the first consumer never saw the record"
            | Ok () -> ());
       let redelivered, redelivered_r = Eio.Promise.create () in
       while_consuming
         ~consume:(fun ~sw ->
           ignore
             (Kafka_service.consume
                svc
                topic
                ~group_id
                ~sw
                ~clock:env#clock
                ~handler:(fun (m : RawTestEvent.t) ~ack ~trace_ctx:_ ->
                  ignore (ack ());
                  ignore (Eio.Promise.try_resolve redelivered_r m.RawTestEvent.id);
                  Kafka.Consumer.Stop)
                ()))
         (fun () ->
            match
              Eio.Time.with_timeout env#clock 30.0 (fun () ->
                Ok (Eio.Promise.await redelivered))
            with
            | Error `Timeout ->
              Windtrap.fail
                "a fact the handler did not acknowledge must come back to the group, not \
                 be skipped"
            | Ok id ->
              Windtrap.equal
                Windtrap.string
                ~msg:"the same record came back"
                "must-redeliver"
                id))
;;

let test_decode_error_routes_to_dlq () =
  with_registered
    (module Drop_event)
    (fun env sw svc topic ->
       let group_id =
         Printf.sprintf "sol-test-decode-dlq-%d-%d" (Unix.getpid ()) (Random.int 9999)
       in
       produce_undecodable ~sw ~topic_name:Drop_event.topic_name;
       (match
          Eio.Promise.await (Kafka_service.publish svc topic Drop_event.{ id = "good" })
        with
        | Error e -> Windtrap.failf "publish failed: %s" (Kafka.Error.to_string e)
        | Ok () -> ());
       let got_good, got_good_r = Eio.Promise.create () in
       while_consuming
         ~consume:(fun ~sw ->
           ignore
             (Kafka_service.consume
                svc
                topic
                ~group_id
                ~sw
                ~clock:env#clock
                ~handler:(fun (m : Drop_event.t) ~ack ~trace_ctx:_ ->
                  ignore (ack ());
                  if m.id = "good" then ignore (Eio.Promise.try_resolve got_good_r ());
                  Kafka.Consumer.Continue)
                ()))
         (fun () ->
            match
              Eio.Time.with_timeout env#clock 30.0 (fun () ->
                Ok (Eio.Promise.await got_good))
            with
            | Error `Timeout ->
              Windtrap.fail "the record after the undecodable one was never reached"
            | Ok () -> ());
       let dlq =
         Kafka_service.Dlq.dlq_topic_name
           ~source:(Kafka_service.topic_name_to_string Drop_event.topic_name)
           ~group_id
       in
       match read_first ~sw ~clock:env#clock ~topic:dlq ~timeout_s:15.0 with
       | None ->
         Windtrap.fail
           "a record the framework could not decode must be parked on the group's DLQ, \
            not dropped"
       | Some record ->
         Windtrap.equal
           (Windtrap.option Windtrap.string)
           ~msg:"the parked record carries the originating group (BUG-030)"
           (Some group_id)
           (List.assoc_opt "X-Sol-Origin-Group" record.Kafka.Consumer.headers
            |> Option.join);
         Windtrap.equal
           Windtrap.bool
           ~msg:"the parked record carries a decode diagnostic"
           true
           (Option.is_some
              (List.assoc_opt "X-Sol-Decode-Error" record.Kafka.Consumer.headers)))
;;

let test_ack_and_drop_opt_in_skips () =
  with_registered
    (module Drop_event)
    (fun env sw svc topic ->
       let group_id =
         Printf.sprintf "sol-test-decode-drop-%d-%d" (Unix.getpid ()) (Random.int 9999)
       in
       produce_undecodable ~sw ~topic_name:Drop_event.topic_name;
       (match
          Eio.Promise.await (Kafka_service.publish svc topic Drop_event.{ id = "good" })
        with
        | Error e -> Windtrap.failf "publish failed: %s" (Kafka.Error.to_string e)
        | Ok () -> ());
       let got_good, got_good_r = Eio.Promise.create () in
       while_consuming
         ~consume:(fun ~sw ->
           ignore
             (Kafka_service.consume
                svc
                topic
                ~group_id
                ~sw
                ~clock:env#clock
                ~decode_error_policy:Kafka_service.Ack_and_drop
                ~handler:(fun (m : Drop_event.t) ~ack ~trace_ctx:_ ->
                  ignore (ack ());
                  if m.id = "good" then ignore (Eio.Promise.try_resolve got_good_r ());
                  Kafka.Consumer.Continue)
                ()))
         (fun () ->
            match
              Eio.Time.with_timeout env#clock 30.0 (fun () ->
                Ok (Eio.Promise.await got_good))
            with
            | Error `Timeout ->
              Windtrap.fail "the record after the undecodable one was never reached"
            | Ok () -> ());
       let dlq =
         Kafka_service.Dlq.dlq_topic_name
           ~source:(Kafka_service.topic_name_to_string Drop_event.topic_name)
           ~group_id
       in
       Windtrap.equal
         Windtrap.bool
         ~msg:"nothing was dead-lettered"
         true
         (Option.is_none (read_first ~sw ~clock:env#clock ~topic:dlq ~timeout_s:5.0)))
;;

module OrderingEvent = struct
  type t =
    { ordering_key : string
    ; seq : int
    }

  let topic_name =
    Kafka_service.topic_name_exn (Printf.sprintf "sol-svc-ordering-%05d" run_id)
  ;;

  let schema =
    {|{
    "type": "object",
    "properties": {
      "ordering_key": { "type": "string"  },
      "seq":          { "type": "integer" }
    },
    "required": ["ordering_key", "seq"]
  }|}
  ;;

  let partitions = 3
  let key t = Some t.ordering_key
  let encode t = `Assoc [ "ordering_key", `String t.ordering_key; "seq", `Int t.seq ]

  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "ordering_key" fields, List.assoc_opt "seq" fields with
       | Some (`String k), Some (`Int s) -> Ok { ordering_key = k; seq = s }
       | _ -> Error "missing required fields")
    | _ -> Error "expected object"
  ;;
end

let test_same_key_records_keep_their_order_across_partitions () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Kafka_service.create (make_config ()) ~sw with
  | Error e -> Windtrap.failf "create failed: %s" (Kafka_service.error_to_string e)
  | Ok svc ->
    (match register svc ~net:env#net ~clock:env#clock (module OrderingEvent) with
     | Error e -> Windtrap.failf "register failed: %s" (Kafka_service.error_to_string e)
     | Ok topic ->
       (match
          Kafka_service.Admin.query_topic_partitions
            env#net
            ~clock:env#clock
            ~admin_url
            ~topic_name:(Kafka_service.topic_name_to_string OrderingEvent.topic_name)
        with
        | Ok (Kafka_service.Admin.Topic_partitions { partitions; _ }) ->
          Windtrap.equal
            Windtrap.int
            ~msg:"the topic got the count the event declares, not a default"
            3
            partitions
        | Ok Kafka_service.Admin.Topic_not_found ->
          Windtrap.fail "the registered topic does not exist"
        | Error e ->
          Windtrap.failf
            "topic metadata: %s"
            (Kafka_service.Admin.topic_partition_error_to_string e));
       let keys = [ "alpha"; "beta"; "gamma" ] in
       let per_key = 4 in
       List.iter
         (fun seq ->
            List.iter
              (fun k ->
                 match
                   Eio.Promise.await
                     (Kafka_service.publish
                        svc
                        topic
                        OrderingEvent.{ ordering_key = k; seq })
                 with
                 | Ok () -> ()
                 | Error e ->
                   Windtrap.failf "publish failed: %s" (Kafka.Error.to_string e))
              keys)
         (List.init per_key (fun i -> i + 1));
       let group_id = Printf.sprintf "sol-test-ordering-%d" (Unix.getpid ()) in
       let target = List.length keys * per_key in
       let observed = ref [] in
       let processed = ref 0 in
       let stop_p, stop_r = Eio.Promise.create () in
       let next_id = ref 0 in
       let start () =
         incr next_id;
         let id = !next_id in
         Kafka_service.consume
           svc
           topic
           ~group_id
           ~sw
           ~clock:env#clock
           ~stop:stop_p
           ~handler:(fun msg ~ack ~trace_ctx:_ ->
             ignore (ack ());
             observed
             := !observed @ [ msg.OrderingEvent.ordering_key, msg.OrderingEvent.seq, id ];
             incr processed;
             if !processed >= target && not (Eio.Promise.is_resolved stop_p)
             then Eio.Promise.resolve stop_r ();
             Kafka.Consumer.Continue)
           ()
       in
       Eio.Fiber.fork ~sw (fun () -> ignore (start ()));
       Eio.Fiber.fork ~sw (fun () -> ignore (start ()));
       (match
          Eio.Time.with_timeout env#clock 60.0 (fun () ->
            Eio.Promise.await stop_p;
            Ok ())
        with
        | Ok () -> ()
        | Error `Timeout ->
          Windtrap.failf
            "only %d of %d records were processed by two members of one group"
            !processed
            target);
       let arrival_order_for key =
         List.filter_map
           (fun (k, s, _) -> if String.equal k key then Some s else None)
           !observed
       in
       let members_for key =
         List.filter_map
           (fun (k, _, id) -> if String.equal k key then Some id else None)
           !observed
         |> List.sort_uniq compare
       in
       List.iter
         (fun key ->
            Windtrap.equal
              (Windtrap.list Windtrap.int)
              ~msg:(Printf.sprintf "every record for %s arrived once, in order" key)
              (List.init per_key (fun i -> i + 1))
              (arrival_order_for key);
            Windtrap.equal
              Windtrap.int
              ~msg:(Printf.sprintf "one member handled every record for %s" key)
              1
              (List.length (members_for key)))
         keys)
;;

let () =
  let open Windtrap in
  run
    "kafka_service_integration"
    [ Windtrap.group
        "schema_check"
        [ test
            "new topic returns ok"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_schema_check_new_topic
        ; test
            "compatible schema returns ok"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_schema_check_compatible
        ; test
            "incompatible schema returns error"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_schema_check_incompatible
        ; test
            "check_all fails fast"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_schema_check_all_fails_fast
        ; test
            "wrong registry path is an error, not compatible"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_schema_check_wrong_registry_path_is_an_error
        ; test
            "contract register sets FULL first and fails loudly"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_contract_register_sets_full_before_registering_and_fails_loudly
        ; test
            "runtime register never writes the registry"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_runtime_register_never_writes_the_registry
        ]
    ; Windtrap.group
        "roundtrip"
        [ test
            "publish and consume"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_publish_consume_roundtrip
        ]
    ; Windtrap.group
        "partitioning"
        [ test
            "same-key records keep their order across partitions"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_same_key_records_keep_their_order_across_partitions
        ]
    ; Windtrap.group
        "durability"
        [ test
            "under-replicated existing topic is rejected"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_single_broker_loss_rejects_under_replicated_topic
        ]
    ; Windtrap.group
        "idle_stop"
        [ test
            "an idle consume returns promptly when stop resolves (BUG-067)"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_consume_returns_promptly_when_idle_and_stop_resolves
        ]
    ; Windtrap.group
        "ack_ownership"
        [ test
            "a fact the handler did not acknowledge is redelivered to its group \
             (FEAT-113)"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_an_unacked_record_is_redelivered_to_the_same_group
        ]
    ; Windtrap.group
        "decode_error_policy"
        [ test
            "a decode failure is parked on the group's DLQ and the next record flows"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_decode_error_routes_to_dlq
        ; test
            "Ack_and_drop opt-in skips and acks"
            ~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)
            test_ack_and_drop_opt_in_skips
        ]
    ]
;;
