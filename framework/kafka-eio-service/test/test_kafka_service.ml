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
  let publish_raw
        ~target_topic:_
        ~attempt:_
        ~raw_bytes:_
        ~key:_
        ~headers:_
        ~delay_s:_
        ~partition:_
    =
    Ok ()
  in
  let ack () =
    incr acked;
    Error Kafka.Error.Application
  in
  let target = Kafka_service.topic_name_exn "orders-retry" in
  let action = Kafka_service.Retry_topics.Forward_retry { target; delay_s = 1.0 } in
  match
    Kafka_service.Retry_topics.execute_action
      action
      ~raw_msg:(raw_retry_msg ())
      ~attempt:1
      ~publish_raw
      ~ack
  with
  | Error Kafka.Error.Application -> Alcotest.(check int) "ack attempted once" 1 !acked
  | _ -> Alcotest.fail "expected ack failure to be returned"
;;

let test_retry_publish_failure_does_not_ack () =
  let acked = ref false in
  let publish_raw
        ~target_topic:_
        ~attempt:_
        ~raw_bytes:_
        ~key:_
        ~headers:_
        ~delay_s:_
        ~partition:_
    =
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
      action
      ~raw_msg:(raw_retry_msg ())
      ~attempt:1
      ~publish_raw
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
  let publish_raw
        ~target_topic
        ~attempt
        ~raw_bytes:_
        ~key:_
        ~headers:_
        ~delay_s
        ~partition:_
    =
    published := Some (target_topic, attempt, delay_s);
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
      ~max_attempts:3
      ~attempt:1
      (Kafka_service.Dead_letter "poison")
  with
  | Error e -> Alcotest.failf "unexpected kafka error: %s" (Kafka.Error.to_string e)
  | Ok action ->
    (match
       Kafka_service.Retry_topics.execute_action
         action
         ~raw_msg:(raw_retry_msg ())
         ~attempt:1
         ~publish_raw
         ~ack
     with
     | Error e -> Alcotest.failf "unexpected execute error: %s" (Kafka.Error.to_string e)
     | Ok () ->
       Alcotest.(check int) "acked once" 1 !acked;
       Alcotest.(check (option (triple string int (float 0.0001))))
         "published to dlq without retry delay"
         (Some (Kafka_service.topic_name_to_string dlq_topic, 1, 0.0))
         (Option.map
            (fun (topic, attempt, delay_s) ->
               Kafka_service.topic_name_to_string topic, attempt, delay_s)
            !published))
;;

(* BUG-027: a retried message's key must travel with it to the retry/DLQ
   topic, so it hashes to the same partition there that it would on the
   source topic (both topics share the same partition count). *)
let test_retry_publish_preserves_key () =
  let published_key = ref `Not_called in
  let publish_raw
        ~target_topic:_
        ~attempt:_
        ~raw_bytes:_
        ~key
        ~headers:_
        ~delay_s:_
        ~partition:_
    =
    published_key := `Called key;
    Ok ()
  in
  let ack () = Ok () in
  let target = Kafka_service.topic_name_exn "orders-retry" in
  let action = Kafka_service.Retry_topics.Forward_retry { target; delay_s = 1.0 } in
  let raw_msg = raw_retry_msg ~key:(Bytes.of_string "order-42") () in
  match
    Kafka_service.Retry_topics.execute_action action ~raw_msg ~attempt:1 ~publish_raw ~ack
  with
  | Error e -> Alcotest.failf "unexpected execute error: %s" (Kafka.Error.to_string e)
  | Ok () ->
    (match !published_key with
     | `Not_called -> Alcotest.fail "publish_raw was never called"
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
  let publish_raw ~target_topic ~attempt ~raw_bytes ~key ~headers ~delay_s ~partition:_ =
    published := Some (target_topic, attempt, raw_bytes, key, headers, delay_s, !acked);
    Ok ()
  in
  let ack () =
    incr acked;
    Ok ()
  in
  match
    Kafka_service.Retry_topics.route_retry_decode_error
      ~dlq_topic
      ~raw_msg
      ~attempt:2
      ~decode_error:"bad json"
      ~publish_raw
      ~ack
  with
  | Error e -> Alcotest.failf "unexpected execute error: %s" (Kafka.Error.to_string e)
  | Ok () ->
    Alcotest.(check int) "acked once" 1 !acked;
    (match !published with
     | None -> Alcotest.fail "publish_raw was never called"
     | Some (target_topic, attempt, raw_bytes, key, headers, delay_s, acked_before) ->
       Alcotest.(check string)
         "target"
         "orders-dlq"
         (Kafka_service.topic_name_to_string target_topic);
       Alcotest.(check int) "attempt preserved" 2 attempt;
       Alcotest.(check (option string))
         "raw payload preserved"
         (Some "payload")
         (Option.map Bytes.to_string raw_bytes);
       Alcotest.(check (option string))
         "key preserved"
         (Some "order-42")
         (Option.map Bytes.to_string key);
       Alcotest.(check (option string))
         "original header preserved"
         (Some "kept")
         (List.assoc_opt "app-header" headers |> Option.join);
       Alcotest.(check (option string))
         "attempt header preserved"
         (Some "2")
         (List.assoc_opt "X-Sol-Attempt" headers |> Option.join);
       Alcotest.(check (option string))
         "retry-at header preserved"
         (Some "123.5")
         (List.assoc_opt "X-Sol-Retry-At" headers |> Option.join);
       Alcotest.(check (option string))
         "decode diagnostic header"
         (Some "bad json")
         (List.assoc_opt "X-Sol-Decode-Error" headers |> Option.join);
       Alcotest.(check (float 0.0001)) "dlq delay" 0.0 delay_s;
       Alcotest.(check int) "publish happened before ack" 0 acked_before)
;;

let test_retry_decode_error_publish_failure_does_not_ack () =
  let dlq_topic = Kafka_service.topic_name_exn "orders-dlq" in
  let acked = ref false in
  let publish_raw
        ~target_topic:_
        ~attempt:_
        ~raw_bytes:_
        ~key:_
        ~headers:_
        ~delay_s:_
        ~partition:_
    =
    Error Kafka.Error.Transport
  in
  let ack () =
    acked := true;
    Ok ()
  in
  match
    Kafka_service.Retry_topics.route_retry_decode_error
      ~dlq_topic
      ~raw_msg:(raw_retry_msg ())
      ~attempt:1
      ~decode_error:"bad json"
      ~publish_raw
      ~ack
  with
  | Error Kafka.Error.Transport -> Alcotest.(check bool) "ack skipped" false !acked
  | _ -> Alcotest.fail "expected publish failure to be returned"
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
      {|{"partitions":[{"id":0},{"id":1},{"id":2}]}|}
  with
  | Ok (Kafka_service.Admin.Topic_partitions partitions) ->
    Alcotest.(check int) "partition count" 3 partitions
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
  check_error "missing partitions" {|{"name":"orders"}|};
  check_error "partitions not list" {|{"partitions":3}|};
  check_error "malformed json" {|{"partitions":|}
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
