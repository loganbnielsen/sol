(** Unit tests for kafka-eio-service. No broker required. *)

(* ------------------------------------------------------------------ *)
(* Wire format — uses the production Confluent_wire codec              *)
(* ------------------------------------------------------------------ *)

let test_wire_roundtrip () =
  let json = `Assoc [ "amount", `Int 100; "currency", `String "USD" ] in
  let schema_id = 42 in
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id json in
  match Kafka_service.Confluent_wire.decode encoded with
  | Error e -> Alcotest.failf "decode failed: %s" e
  | Ok (got_id, json_str) ->
    Alcotest.(check int) "schema id roundtrips" schema_id got_id;
    let decoded = Yojson.Safe.from_string json_str in
    Alcotest.(check string)
      "json roundtrips"
      (Yojson.Safe.to_string json)
      (Yojson.Safe.to_string decoded)
;;

let test_wire_large_schema_id () =
  let schema_id = 0x00FFFFFF in
  let json = `String "hello" in
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id json in
  match Kafka_service.Confluent_wire.decode encoded with
  | Error e -> Alcotest.failf "decode failed: %s" e
  | Ok (got_id, _) -> Alcotest.(check int) "large schema id roundtrips" schema_id got_id
;;

let test_wire_bad_magic () =
  let bad = Bytes.of_string "\x01\x00\x00\x00\x01{}" in
  Alcotest.(check bool)
    "bad magic returns error"
    true
    (Result.is_error (Kafka_service.Confluent_wire.decode bad))
;;

let test_wire_too_short () =
  let bad = Bytes.of_string "\x00\x00" in
  Alcotest.(check bool)
    "too short returns error"
    true
    (Result.is_error (Kafka_service.Confluent_wire.decode bad))
;;

let test_wire_magic_byte () =
  (* Verify the first byte of any encoded message is 0x00 *)
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id:1 (`String "x") in
  Alcotest.(check char) "magic byte is 0x00" '\x00' (Bytes.get encoded 0)
;;

let test_wire_schema_id_big_endian () =
  (* schema_id 0x01020304 must appear at bytes 1..4 in big-endian order *)
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id:0x01020304 (`String "x") in
  Alcotest.(check char) "byte 1" '\x01' (Bytes.get encoded 1);
  Alcotest.(check char) "byte 2" '\x02' (Bytes.get encoded 2);
  Alcotest.(check char) "byte 3" '\x03' (Bytes.get encoded 3);
  Alcotest.(check char) "byte 4" '\x04' (Bytes.get encoded 4)
;;

(* ------------------------------------------------------------------ *)
(* URL construction via Uri (replaces hand-written parse_base_url)    *)
(* ------------------------------------------------------------------ *)

(* Exercises the same Uri.of_string (base_url ^ path) parsing http_do_once
   uses in production. *)

let check_uri msg ~expected_host ~expected_port ~expected_scheme url =
  let u = Uri.of_string url in
  Alcotest.(check (option string)) (msg ^ " host") (Some expected_host) (Uri.host u);
  Alcotest.(check (option int)) (msg ^ " port") expected_port (Uri.port u);
  Alcotest.(check (option string)) (msg ^ " scheme") (Some expected_scheme) (Uri.scheme u)
;;

let test_parse_url () =
  check_uri
    "http://localhost:8081"
    ~expected_host:"localhost"
    ~expected_port:(Some 8081)
    ~expected_scheme:"http"
    "http://localhost:8081";
  check_uri
    "http://localhost:9644"
    ~expected_host:"localhost"
    ~expected_port:(Some 9644)
    ~expected_scheme:"http"
    "http://localhost:9644";
  check_uri
    "http no explicit port"
    ~expected_host:"localhost"
    ~expected_port:None
    ~expected_scheme:"http"
    "http://localhost"
;;

let test_parse_url_https () =
  check_uri
    "https:// with explicit port"
    ~expected_host:"registry.example.com"
    ~expected_port:(Some 8081)
    ~expected_scheme:"https"
    "https://registry.example.com:8081";
  check_uri
    "https:// no explicit port"
    ~expected_host:"registry.confluent.io"
    ~expected_port:None
    ~expected_scheme:"https"
    "https://registry.confluent.io"
;;

(* ------------------------------------------------------------------ *)
(* Env config                                                          *)
(* ------------------------------------------------------------------ *)

let contains s sub =
  let slen = String.length s
  and sublen = String.length sub in
  if sublen = 0
  then true
  else if sublen > slen
  then false
  else (
    let rec go i =
      if i > slen - sublen
      then false
      else if String.sub s i sublen = sub
      then true
      else go (i + 1)
    in
    go 0)
;;

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect f ~finally:(fun () -> Unix.putenv name (Option.value old ~default:""))
;;

let test_config_of_env_rejects_unknown_security_protocol () =
  with_env "KAFKA_SECURITY_PROTOCOL" "scram" (fun () ->
    match Kafka_service.config_of_env () with
    | Ok _ -> Alcotest.fail "expected invalid security protocol to fail"
    | Error e ->
      Alcotest.(check bool)
        "clear env protocol error"
        true
        (contains (Kafka_service.error_to_string e) "KAFKA_SECURITY_PROTOCOL"))
;;

(* SEC-007 / FND-0039: an absent (or blank) protocol is an error, not an
   implicit plaintext. *)
let test_config_of_env_requires_security_protocol () =
  with_env "KAFKA_SECURITY_PROTOCOL" "" (fun () ->
    match Kafka_service.config_of_env () with
    | Ok _ -> Alcotest.fail "an unstated transport posture must not default to plaintext"
    | Error e ->
      Alcotest.(check bool)
        "names the variable"
        true
        (contains (Kafka_service.error_to_string e) "KAFKA_SECURITY_PROTOCOL"));
  with_env "KAFKA_SECURITY_PROTOCOL" "plaintext" (fun () ->
    Alcotest.(check bool)
      "stated plaintext is accepted"
      true
      (Result.is_ok (Kafka_service.config_of_env ())))
;;

let test_config_of_env_topic_durability () =
  with_env "KAFKA_SECURITY_PROTOCOL" "plaintext"
  @@ fun () ->
  with_env "SOL_KAFKA_DURABILITY" "single-broker-loss" (fun () ->
    match Kafka_service.config_of_env () with
    | Error e -> Alcotest.fail (Kafka_service.error_to_string e)
    | Ok config ->
      Alcotest.(check bool)
        "semantic policy"
        true
        (config.topic_durability = Kafka_service.Single_broker_loss));
  with_env "SOL_KAFKA_DURABILITY" "unsupported" (fun () ->
    match Kafka_service.config_of_env () with
    | Ok _ -> Alcotest.fail "expected invalid durability policy to fail"
    | Error e ->
      Alcotest.(check bool)
        "clear durability error"
        true
        (contains (Kafka_service.error_to_string e) "SOL_KAFKA_DURABILITY"))
;;

(* ------------------------------------------------------------------ *)
(* Retry topic control flow                                            *)
(* ------------------------------------------------------------------ *)

let raw_retry_msg ?(headers = []) ?key () : Kafka.Consumer.message =
  { topic = "orders-retry"
  ; partition = 0l
  ; offset = 0L
  ; key
  ; value = Some (Bytes.of_string "payload")
  ; timestamp = None
  ; headers
  }
;;

let test_retry_metadata_rejects_malformed_headers () =
  let check_error name headers =
    match Kafka_service.Retry_topics.parse_retry_metadata headers with
    | Ok _ -> Alcotest.failf "%s: expected retry metadata error" name
    | Error _ -> ()
  in
  let valid = [ "X-Sol-Attempt", Some "2"; "X-Sol-Retry-At", Some "123.5" ] in
  Alcotest.(check (result (pair int (float 0.0001)) string))
    "valid retry metadata"
    (Ok (2, 123.5))
    (Kafka_service.Retry_topics.parse_retry_metadata valid);
  check_error "missing attempt" [ "X-Sol-Retry-At", Some "123.5" ];
  check_error "zero attempt" [ "X-Sol-Attempt", Some "0"; "X-Sol-Retry-At", Some "123.5" ];
  check_error
    "bad attempt"
    [ "X-Sol-Attempt", Some "nan"; "X-Sol-Retry-At", Some "123.5" ];
  check_error "missing retry_at" [ "X-Sol-Attempt", Some "1" ];
  check_error "bad retry_at" [ "X-Sol-Attempt", Some "1"; "X-Sol-Retry-At", Some "soon" ]
;;

let test_retry_publish_then_ack_failure_is_error () =
  let acked = ref 0 in
  let publish ~target_topic:_ (_ : Kafka_service.Retry_topics.relay) = Ok () in
  let ack () =
    incr acked;
    Error Kafka.Error.Application
  in
  let target = Kafka_service.topic_name_exn "orders-retry" in
  let action = Kafka_service.Retry_topics.Forward_retry { target; delay_s = 1.0 } in
  match
    Kafka_service.Retry_topics.execute_action
      ~group_id:"test-group"
      action
      ~raw_msg:(raw_retry_msg ())
      ~attempt:1
      ~publish
      ~ack
  with
  | Error Kafka.Error.Application -> Alcotest.(check int) "ack attempted once" 1 !acked
  | _ -> Alcotest.fail "expected ack failure to be returned"
;;

let test_retry_publish_failure_does_not_ack () =
  let acked = ref false in
  let publish ~target_topic:_ (_ : Kafka_service.Retry_topics.relay) =
    Error Kafka.Error.Transport
  in
  let ack () =
    acked := true;
    Ok ()
  in
  let target = Kafka_service.topic_name_exn "orders-dlq" in
  let action = Kafka_service.Retry_topics.Forward_dlq { target } in
  match
    Kafka_service.Retry_topics.execute_action
      ~group_id:"test-group"
      action
      ~raw_msg:(raw_retry_msg ())
      ~attempt:1
      ~publish
      ~ack
  with
  | Error Kafka.Error.Transport -> Alcotest.(check bool) "ack skipped" false !acked
  | _ -> Alcotest.fail "expected publish failure to be returned"
;;

let test_dead_letter_handler_error_routes_to_dlq_and_acks () =
  let retry_topic = Kafka_service.topic_name_exn "orders-retry" in
  let dlq_topic = Kafka_service.topic_name_exn "orders-dlq" in
  let acked = ref 0 in
  let published = ref None in
  let publish ~target_topic (msg : Kafka_service.Retry_topics.relay) =
    published := Some (target_topic, msg);
    Ok ()
  in
  let ack () =
    incr acked;
    Ok ()
  in
  match
    Kafka_service.Retry_topics.action_of_handler_error
      ~retry_topic
      ~dlq_topic
      ~retry_policy:
        { base_delay_s = 1.0; max_delay_s = 60.0; max_attempts = 3; jitter_ratio = 0.0 }
      ~attempt:1
      (Kafka_service.Dead_letter "poison")
  with
  | Error e -> Alcotest.failf "unexpected kafka error: %s" (Kafka.Error.to_string e)
  | Ok action ->
    (match
       Kafka_service.Retry_topics.execute_action
         ~group_id:"test-group"
         action
         ~raw_msg:(raw_retry_msg ())
         ~attempt:1
         ~publish
         ~ack
     with
     | Error e -> Alcotest.failf "unexpected execute error: %s" (Kafka.Error.to_string e)
     | Ok () ->
       Alcotest.(check int) "acked once" 1 !acked;
       (match !published with
        | None -> Alcotest.fail "publish was never called"
        | Some (target_topic, (msg : Kafka_service.Retry_topics.relay)) ->
          Alcotest.(check (triple string int (float 0.0001)))
            "published to dlq without retry delay"
            (Kafka_service.topic_name_to_string dlq_topic, 1, 0.0)
            (Kafka_service.topic_name_to_string target_topic, msg.attempt, msg.delay_s);
          Alcotest.(check (option string))
            "origin-group header (BUG-030)"
            (Some "test-group")
            (List.assoc_opt "X-Sol-Origin-Group" msg.headers |> Option.join)))
;;

(* FEAT-078: a Retry within budget schedules a delay via the same jittered
   backoff In_memory uses (Kafka.Consumer.backoff_s), bounded by the shared
   retry_policy's max_delay_s -- and exhausting the budget still routes to
   the DLQ, exactly as before the retry_policy unification. *)
let test_retry_within_budget_schedules_jittered_bounded_delay () =
  let retry_topic = Kafka_service.topic_name_exn "orders-retry" in
  let dlq_topic = Kafka_service.topic_name_exn "orders-dlq" in
  let retry_policy : Kafka.Consumer.retry_policy =
    { base_delay_s = 1.0; max_delay_s = 5.0; max_attempts = 5; jitter_ratio = 0.3 }
  in
  for attempt = 1 to retry_policy.max_attempts - 1 do
    match
      Kafka_service.Retry_topics.action_of_handler_error
        ~retry_topic
        ~dlq_topic
        ~retry_policy
        ~attempt
        Kafka_service.Retry
    with
    | Error e -> Alcotest.failf "unexpected kafka error: %s" (Kafka.Error.to_string e)
    | Ok (Kafka_service.Retry_topics.Forward_retry { target; delay_s }) ->
      Alcotest.(check string)
        "targets the retry topic"
        "orders-retry"
        (Kafka_service.topic_name_to_string target);
      Alcotest.(check bool)
        (Printf.sprintf "attempt %d delay within [0, max_delay_s]" attempt)
        true
        (delay_s >= 0.0 && delay_s <= retry_policy.max_delay_s)
    | Ok _ -> Alcotest.failf "attempt %d: expected Forward_retry, not Forward_dlq" attempt
  done;
  match
    Kafka_service.Retry_topics.action_of_handler_error
      ~retry_topic
      ~dlq_topic
      ~retry_policy
      ~attempt:retry_policy.max_attempts
      Kafka_service.Retry
  with
  | Ok (Kafka_service.Retry_topics.Forward_dlq { target }) ->
    Alcotest.(check string)
      "exhausted budget routes to the dlq topic"
      "orders-dlq"
      (Kafka_service.topic_name_to_string target)
  | Ok (Kafka_service.Retry_topics.Forward_retry _) ->
    Alcotest.fail "expected the exhausted attempt to route to the dlq, not retry again"
  | Ok Kafka_service.Retry_topics.Ack ->
    Alcotest.fail "expected the exhausted attempt to route to the dlq, not ack"
  | Error e -> Alcotest.failf "unexpected kafka error: %s" (Kafka.Error.to_string e)
;;

(* BUG-027: a retried message's key must travel with it to the retry/DLQ
   topic, so it hashes to the same partition there that it would on the
   source topic (both topics share the same partition count). *)
let test_retry_publish_preserves_key () =
  let published_key = ref `Not_called in
  let publish ~target_topic:_ (msg : Kafka_service.Retry_topics.relay) =
    published_key := `Called msg.source.Kafka.Consumer.key;
    Ok ()
  in
  let ack () = Ok () in
  let target = Kafka_service.topic_name_exn "orders-retry" in
  let action = Kafka_service.Retry_topics.Forward_retry { target; delay_s = 1.0 } in
  let raw_msg = raw_retry_msg ~key:(Bytes.of_string "order-42") () in
  match
    Kafka_service.Retry_topics.execute_action
      ~group_id:"test-group"
      action
      ~raw_msg
      ~attempt:1
      ~publish
      ~ack
  with
  | Error e -> Alcotest.failf "unexpected execute error: %s" (Kafka.Error.to_string e)
  | Ok () ->
    (match !published_key with
     | `Not_called -> Alcotest.fail "publish was never called"
     | `Called None -> Alcotest.fail "expected the original message's key, got None"
     | `Called (Some key) ->
       Alcotest.(check string)
         "key preserved on republish"
         "order-42"
         (Bytes.to_string key))
;;

(* BUG-029: the relay's produce backoff schedule -- bounded, non-negative, and
   the cap is exact once jitter can no longer push a large raw delay under it. *)
let test_produce_backoff_s_early_attempt_within_jittered_bounds () =
  let v = Kafka_service.Retry_topics.produce_backoff_s 1 in
  Alcotest.(check bool)
    "attempt 1 backoff is within +-20% of 0.1s"
    true
    (v >= 0.08 && v <= 0.12)
;;

let test_produce_backoff_s_caps_at_max_delay () =
  (* raw = 0.1 * 2^9 = 51.2s, far past the 5s cap even at the low end of
     jitter -- the cap must be exact regardless of the random draw. *)
  Alcotest.(check (float 0.0))
    "large attempt clamps to the cap"
    5.0
    (Kafka_service.Retry_topics.produce_backoff_s 10)
;;

let test_produce_backoff_s_never_negative () =
  Alcotest.(check bool)
    "attempt 1 backoff is non-negative"
    true
    (Kafka_service.Retry_topics.produce_backoff_s 1 >= 0.0)
;;

(* BUG-029: retry_produce's control flow, fully deterministic via stubbed
   produce/sleep/backoff_s/on_retry -- no live broker, no real clock. *)
let test_retry_produce_succeeds_immediately_without_retrying () =
  let produce_calls = ref 0 in
  let sleeps = ref [] in
  let retries = ref [] in
  match
    Kafka_service.Retry_topics.retry_produce
      ~max_attempts:5
      ~backoff_s:(fun n -> Float.of_int n)
      ~sleep:(fun s -> sleeps := s :: !sleeps)
      ~on_retry:(fun ~attempt ~error -> retries := (attempt, error) :: !retries)
      ~produce:(fun () ->
        incr produce_calls;
        Ok ())
      ()
  with
  | Error _ -> Alcotest.fail "expected immediate success"
  | Ok () ->
    Alcotest.(check int) "produce called once" 1 !produce_calls;
    Alcotest.(check int) "no sleeps" 0 (List.length !sleeps);
    Alcotest.(check int) "no retries reported" 0 (List.length !retries)
;;

let test_retry_produce_recovers_after_transient_failures () =
  let attempts_seen = ref [] in
  let sleeps = ref [] in
  let call_count = ref 0 in
  match
    Kafka_service.Retry_topics.retry_produce
      ~max_attempts:5
      ~backoff_s:(fun n -> Float.of_int n *. 0.01)
      ~sleep:(fun s -> sleeps := s :: !sleeps)
      ~on_retry:(fun ~attempt ~error:_ -> attempts_seen := attempt :: !attempts_seen)
      ~produce:(fun () ->
        incr call_count;
        if !call_count < 3 then Error "boom" else Ok ())
      ()
  with
  | Error _ -> Alcotest.fail "expected eventual success"
  | Ok () ->
    Alcotest.(check int) "produce called 3 times" 3 !call_count;
    Alcotest.(check (list int)) "retried after attempts 1 and 2" [ 2; 1 ] !attempts_seen;
    Alcotest.(check (list (float 0.0001)))
      "slept with backoff_s(1) then backoff_s(2)"
      [ 0.02; 0.01 ]
      !sleeps
;;

let test_retry_produce_gives_up_after_max_attempts () =
  let call_count = ref 0 in
  let retries = ref 0 in
  match
    Kafka_service.Retry_topics.retry_produce
      ~max_attempts:3
      ~backoff_s:(fun _ -> 0.0)
      ~sleep:(fun _ -> ())
      ~on_retry:(fun ~attempt:_ ~error:_ -> incr retries)
      ~produce:(fun () ->
        incr call_count;
        Error "always fails")
      ()
  with
  | Ok () -> Alcotest.fail "expected exhaustion"
  | Error e ->
    Alcotest.(check string) "final error surfaces" "always fails" e;
    Alcotest.(check int) "produce called exactly max_attempts times" 3 !call_count;
    (* on_retry fires between attempts, never on the final give-up. *)
    Alcotest.(check int) "on_retry called max_attempts - 1 times" 2 !retries
;;

let test_retry_decode_error_routes_to_dlq_and_acks_after_publish () =
  let dlq_topic = Kafka_service.topic_name_exn "orders-dlq" in
  let acked = ref 0 in
  let published = ref None in
  let raw_msg =
    raw_retry_msg
      ~key:(Bytes.of_string "order-42")
      ~headers:
        [ "X-Sol-Attempt", Some "2"
        ; "X-Sol-Retry-At", Some "123.5"
        ; "app-header", Some "kept"
        ]
      ()
  in
  let publish ~target_topic (msg : Kafka_service.Retry_topics.relay) =
    published := Some (target_topic, msg, !acked);
    Ok ()
  in
  let ack () =
    incr acked;
    Ok ()
  in
  match
    Kafka_service.Retry_topics.route_decode_error
      ~stage:`Retry
      ~dlq_topic
      ~raw_msg
      ~attempt:2
      ~decode_error:"bad json"
      ~group_id:"test-group"
      ~publish
      ~ack
  with
  | Error e -> Alcotest.failf "unexpected execute error: %s" (Kafka.Error.to_string e)
  | Ok () ->
    Alcotest.(check int) "acked once" 1 !acked;
    (match !published with
     | None -> Alcotest.fail "publish was never called"
     | Some (target_topic, (msg : Kafka_service.Retry_topics.relay), acked_before) ->
       Alcotest.(check string)
         "target"
         "orders-dlq"
         (Kafka_service.topic_name_to_string target_topic);
       Alcotest.(check int) "attempt preserved" 2 msg.attempt;
       Alcotest.(check (option string))
         "raw payload preserved"
         (Some "payload")
         (Option.map Bytes.to_string msg.source.Kafka.Consumer.value);
       Alcotest.(check (option string))
         "key preserved"
         (Some "order-42")
         (Option.map Bytes.to_string msg.source.Kafka.Consumer.key);
       Alcotest.(check (option string))
         "original header preserved"
         (Some "kept")
         (List.assoc_opt "app-header" msg.headers |> Option.join);
       Alcotest.(check (option string))
         "attempt header preserved"
         (Some "2")
         (List.assoc_opt "X-Sol-Attempt" msg.headers |> Option.join);
       Alcotest.(check (option string))
         "retry-at header preserved"
         (Some "123.5")
         (List.assoc_opt "X-Sol-Retry-At" msg.headers |> Option.join);
       Alcotest.(check (option string))
         "decode diagnostic header"
         (Some "bad json")
         (List.assoc_opt "X-Sol-Decode-Error" msg.headers |> Option.join);
       Alcotest.(check (option string))
         "origin-group header (BUG-030)"
         (Some "test-group")
         (List.assoc_opt "X-Sol-Origin-Group" msg.headers |> Option.join);
       Alcotest.(check (float 0.0001)) "dlq delay" 0.0 msg.delay_s;
       Alcotest.(check int) "publish happened before ack" 0 acked_before)
;;

let test_retry_decode_error_publish_failure_does_not_ack () =
  let dlq_topic = Kafka_service.topic_name_exn "orders-dlq" in
  let acked = ref false in
  let publish ~target_topic:_ (_ : Kafka_service.Retry_topics.relay) =
    Error Kafka.Error.Transport
  in
  let ack () =
    acked := true;
    Ok ()
  in
  match
    Kafka_service.Retry_topics.route_decode_error
      ~stage:`Retry
      ~dlq_topic
      ~raw_msg:(raw_retry_msg ())
      ~attempt:1
      ~decode_error:"bad json"
      ~group_id:"test-group"
      ~publish
      ~ack
  with
  | Error Kafka.Error.Transport -> Alcotest.(check bool) "ack skipped" false !acked
  | _ -> Alcotest.fail "expected publish failure to be returned"
;;

(* BUG-030: retry/DLQ topic names must be scoped by consumer group, or
   independent groups on the same source topic consume each other's
   retries/dead-letters. *)
let test_relay_topic_name_scopes_by_group () =
  Alcotest.(check string)
    "canonical shape"
    "orders.payments.retry"
    (Kafka_service.Retry_topics.relay_topic_name
       ~source:"orders"
       ~group_id:"payments"
       ~suffix:"retry");
  Alcotest.(check bool)
    "two groups on the same source topic get distinct topic names"
    true
    (String.equal
       (Kafka_service.Retry_topics.relay_topic_name
          ~source:"orders"
          ~group_id:"payments"
          ~suffix:"dlq")
       (Kafka_service.Retry_topics.relay_topic_name
          ~source:"orders"
          ~group_id:"analytics"
          ~suffix:"dlq")
     |> not)
;;

let test_relay_topic_name_sanitizes_invalid_characters () =
  Alcotest.(check string)
    "dots and slashes become hyphens"
    "orders.pay-ments-v1-eu-west-1.retry"
    (Kafka_service.Retry_topics.relay_topic_name
       ~source:"orders"
       ~group_id:"pay.ments/v1_eu:west-1"
       ~suffix:"retry")
;;

let test_relay_topic_name_empty_group_id_is_unscoped () =
  Alcotest.(check string)
    "empty group id"
    "orders.unscoped.retry"
    (Kafka_service.Retry_topics.relay_topic_name
       ~source:"orders"
       ~group_id:""
       ~suffix:"retry")
;;

let test_relay_topic_name_truncates_overlong_group_ids_deterministically () =
  let long_group = String.make 200 'g' in
  let name1 =
    Kafka_service.Retry_topics.relay_topic_name
      ~source:"orders"
      ~group_id:long_group
      ~suffix:"retry"
  in
  let name2 =
    Kafka_service.Retry_topics.relay_topic_name
      ~source:"orders"
      ~group_id:long_group
      ~suffix:"retry"
  in
  Alcotest.(check string) "deterministic for the same group id" name1 name2;
  Alcotest.(check bool)
    "stays well under Kafka's 249-byte limit"
    true
    (String.length name1 < 249);
  let other_long_group = String.make 200 'h' in
  let name3 =
    Kafka_service.Retry_topics.relay_topic_name
      ~source:"orders"
      ~group_id:other_long_group
      ~suffix:"retry"
  in
  Alcotest.(check bool)
    "two different overlong group ids never truncate to the same name"
    true
    (not (String.equal name1 name3))
;;

(* ------------------------------------------------------------------ *)
(* Topic names                                                         *)
(* ------------------------------------------------------------------ *)

let test_topic_name_accepts_kafka_compatible_names () =
  let check name =
    match Kafka_service.topic_name name with
    | Ok topic ->
      Alcotest.(check string) name name (Kafka_service.topic_name_to_string topic)
    | Error e ->
      Alcotest.failf "%s should be valid: %s" name (Kafka_service.error_to_string e)
  in
  List.iter
    check
    [ "orders"; "sol-demo-orders"; "payments.charges_v1"; "__consumer_offsets" ]
;;

let test_topic_name_rejects_invalid_names () =
  let long_name = String.make 250 'a' in
  let check name =
    match Kafka_service.topic_name name with
    | Ok _ -> Alcotest.failf "%S should be invalid" name
    | Error _ -> ()
  in
  List.iter check [ ""; "."; ".."; "orders/v1"; "orders v1"; long_name ]
;;

(* ------------------------------------------------------------------ *)
(* Schema Registry response decoding                                  *)
(* ------------------------------------------------------------------ *)

let result_error () =
  Alcotest.testable
    (fun fmt -> function
       | Ok _ -> Format.fprintf fmt "Ok _"
       | Error e -> Format.fprintf fmt "Error %S" e)
    ( = )
;;

let test_decode_compatibility_response () =
  match Kafka_service.Schema.decode_compatibility_response {|{"is_compatible":true}|} with
  | Ok response ->
    Alcotest.(check bool) "is compatible" true response.Kafka_service.Schema.is_compatible
  | Error e -> Alcotest.failf "decode failed: %s" e
;;

(* BUG-049: only "no such subject/version" 404s mean "nothing to be compatible
   with"; a 404 from a request that never reached the subjects API does not. *)
let test_is_subject_not_found () =
  let yes body = Kafka_service.Schema.is_subject_not_found body in
  Alcotest.(check bool)
    "40401"
    true
    (yes {|{"error_code":40401,"message":"Subject not found."}|});
  Alcotest.(check bool)
    "40402"
    true
    (yes {|{"error_code":40402,"message":"Version not found."}|});
  Alcotest.(check bool)
    "plain 404 (wrong path)"
    false
    (yes {|{"error_code":404,"message":"HTTP 404 Not Found"}|});
  Alcotest.(check bool) "non-JSON 404" false (yes "<html>404</html>");
  Alcotest.(check bool) "empty" false (yes "")
;;

let test_decode_compatibility_response_errors () =
  Alcotest.(check (result_error ()))
    "missing field"
    (Error {|unexpected registry response: {"ok":true}|})
    (Kafka_service.Schema.decode_compatibility_response {|{"ok":true}|});
  Alcotest.(check (result_error ()))
    "malformed json"
    (Error {|json parse error in registry response: {"is_compatible":|})
    (Kafka_service.Schema.decode_compatibility_response {|{"is_compatible":|})
;;

let test_decode_registration_response () =
  match Kafka_service.Schema.decode_registration_response {|{"id":42}|} with
  | Ok response -> Alcotest.(check int) "schema id" 42 response.Kafka_service.Schema.id
  | Error e -> Alcotest.failf "decode failed: %s" e
;;

let test_decode_registration_response_errors () =
  Alcotest.(check (result_error ()))
    "missing id"
    (Error {|schema registry: missing 'id' in: {"schema":{}}|})
    (Kafka_service.Schema.decode_registration_response {|{"schema":{}}|});
  Alcotest.(check (result_error ()))
    "unexpected shape"
    (Error {|schema registry: unexpected response: []|})
    (Kafka_service.Schema.decode_registration_response {|[]|});
  Alcotest.(check (result_error ()))
    "malformed json"
    (Error {|schema registry: json parse error in: {"id":|})
    (Kafka_service.Schema.decode_registration_response {|{"id":|})
;;

(* ------------------------------------------------------------------ *)
(* Redpanda admin topic metadata decoding                             *)
(* ------------------------------------------------------------------ *)

let test_decode_topic_partitions () =
  match
    Kafka_service.Admin.decode_topic_partitions
      {|[{"partition_id":0,"replicas":[{"node_id":0},{"node_id":1},{"node_id":2}]},{"partition_id":1,"replicas":[{"node_id":1},{"node_id":2},{"node_id":0}]}]|}
  with
  | Ok (Kafka_service.Admin.Topic_partitions { partitions; replication_factor }) ->
    Alcotest.(check int) "partition count" 2 partitions;
    Alcotest.(check int) "replication factor" 3 replication_factor
  | Ok Kafka_service.Admin.Topic_not_found ->
    Alcotest.fail "decoder should not return Topic_not_found for HTTP 200"
  | Error e ->
    Alcotest.failf
      "decode failed: %s"
      (Kafka_service.Admin.topic_partition_error_to_string e)
;;

let test_decode_topic_partitions_errors () =
  let check_error name body =
    match Kafka_service.Admin.decode_topic_partitions body with
    | Ok _ -> Alcotest.failf "%s: expected malformed response" name
    | Error e ->
      Alcotest.(check string)
        name
        ("malformed admin API topic response: " ^ body)
        (Kafka_service.Admin.topic_partition_error_to_string e)
  in
  check_error "object instead of list" {|{"name":"orders"}|};
  check_error "missing replicas" {|[{"partition_id":0}]|};
  check_error "empty partitions" {|[]|};
  check_error "malformed json" {|[{"partition_id":|}
;;

(* ------------------------------------------------------------------ *)
(* Runner                                                              *)
(* ------------------------------------------------------------------ *)

let () =
  let open Alcotest in
  run
    "kafka_service"
    [ ( "wire_format"
      , [ test_case "roundtrip" `Quick test_wire_roundtrip
        ; test_case "large schema id" `Quick test_wire_large_schema_id
        ; test_case "bad magic byte" `Quick test_wire_bad_magic
        ; test_case "too short" `Quick test_wire_too_short
        ; test_case "magic byte is 0x00" `Quick test_wire_magic_byte
        ; test_case "schema id big-endian" `Quick test_wire_schema_id_big_endian
        ] )
    ; ( "url_parser"
      , [ test_case "parse base url" `Quick test_parse_url
        ; test_case "https:// tls=true" `Quick test_parse_url_https
        ] )
    ; ( "config"
      , [ test_case
            "unknown security protocol fails clearly"
            `Quick
            test_config_of_env_rejects_unknown_security_protocol
        ; test_case
            "requires KAFKA_SECURITY_PROTOCOL"
            `Quick
            test_config_of_env_requires_security_protocol
        ; test_case "topic durability" `Quick test_config_of_env_topic_durability
        ] )
    ; ( "retry_topics"
      , [ test_case
            "malformed retry headers are rejected"
            `Quick
            test_retry_metadata_rejects_malformed_headers
        ; test_case
            "ack failure after publish is returned"
            `Quick
            test_retry_publish_then_ack_failure_is_error
        ; test_case
            "publish failure does not ack"
            `Quick
            test_retry_publish_failure_does_not_ack
        ; test_case
            "dead-letter handler error routes to dlq and acks"
            `Quick
            test_dead_letter_handler_error_routes_to_dlq_and_acks
        ; test_case
            "retry within budget schedules jittered bounded delay"
            `Quick
            test_retry_within_budget_schedules_jittered_bounded_delay
        ; test_case
            "retry publish preserves the message key"
            `Quick
            test_retry_publish_preserves_key
        ; test_case
            "produce backoff: early attempt within jittered bounds"
            `Quick
            test_produce_backoff_s_early_attempt_within_jittered_bounds
        ; test_case
            "produce backoff: caps at max delay"
            `Quick
            test_produce_backoff_s_caps_at_max_delay
        ; test_case
            "produce backoff: never negative"
            `Quick
            test_produce_backoff_s_never_negative
        ; test_case
            "retry_produce: succeeds immediately without retrying"
            `Quick
            test_retry_produce_succeeds_immediately_without_retrying
        ; test_case
            "retry_produce: recovers after transient failures"
            `Quick
            test_retry_produce_recovers_after_transient_failures
        ; test_case
            "retry_produce: gives up after max attempts"
            `Quick
            test_retry_produce_gives_up_after_max_attempts
        ; test_case
            "retry decode error routes to dlq and acks after publish"
            `Quick
            test_retry_decode_error_routes_to_dlq_and_acks_after_publish
        ; test_case
            "retry decode error publish failure does not ack"
            `Quick
            test_retry_decode_error_publish_failure_does_not_ack
        ; test_case
            "relay topic name scopes by group"
            `Quick
            test_relay_topic_name_scopes_by_group
        ; test_case
            "relay topic name sanitizes invalid characters"
            `Quick
            test_relay_topic_name_sanitizes_invalid_characters
        ; test_case
            "relay topic name: empty group id is unscoped"
            `Quick
            test_relay_topic_name_empty_group_id_is_unscoped
        ; test_case
            "relay topic name truncates overlong group ids deterministically"
            `Quick
            test_relay_topic_name_truncates_overlong_group_ids_deterministically
        ] )
    ; ( "topic_name"
      , [ test_case
            "accepts Kafka-compatible names"
            `Quick
            test_topic_name_accepts_kafka_compatible_names
        ; test_case "rejects invalid names" `Quick test_topic_name_rejects_invalid_names
        ] )
    ; ( "schema_registry_decoding"
      , [ test_case "compatibility response" `Quick test_decode_compatibility_response
        ; test_case
            "compatibility response errors"
            `Quick
            test_decode_compatibility_response_errors
        ; test_case "is_subject_not_found (BUG-049)" `Quick test_is_subject_not_found
        ; test_case "registration response" `Quick test_decode_registration_response
        ; test_case
            "registration response errors"
            `Quick
            test_decode_registration_response_errors
        ] )
    ; ( "admin_topic_metadata"
      , [ test_case "topic partitions" `Quick test_decode_topic_partitions
        ; test_case "topic partition errors" `Quick test_decode_topic_partitions_errors
        ] )
    ]
;;
