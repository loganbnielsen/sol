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
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id:1 (`String "x") in
  Alcotest.(check char) "magic byte is 0x00" '\x00' (Bytes.get encoded 0)
;;

let test_wire_schema_id_big_endian () =
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id:0x01020304 (`String "x") in
  Alcotest.(check char) "byte 1" '\x01' (Bytes.get encoded 1);
  Alcotest.(check char) "byte 2" '\x02' (Bytes.get encoded 2);
  Alcotest.(check char) "byte 3" '\x03' (Bytes.get encoded 3);
  Alcotest.(check char) "byte 4" '\x04' (Bytes.get encoded 4)
;;

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

let with_kafka_env f =
  with_env "KAFKA_SECURITY_PROTOCOL" "plaintext" (fun () ->
    with_env "KAFKA_BROKERS" "localhost:9092" (fun () ->
      with_env "SCHEMA_REGISTRY_URL" "http://localhost:8081" (fun () ->
        with_env "REDPANDA_ADMIN_URL" "http://localhost:9644" f)))
;;

let test_config_of_env_rejects_unknown_security_protocol () =
  with_kafka_env
  @@ fun () ->
  with_env "KAFKA_SECURITY_PROTOCOL" "scram" (fun () ->
    match Kafka_service.config_of_env () with
    | Ok _ -> Alcotest.fail "expected invalid security protocol to fail"
    | Error e ->
      Alcotest.(check bool)
        "clear env protocol error"
        true
        (contains (Kafka_service.error_to_string e) "KAFKA_SECURITY_PROTOCOL"))
;;

let test_config_of_env_requires_security_protocol () =
  with_kafka_env
  @@ fun () ->
  with_env "KAFKA_SECURITY_PROTOCOL" "" (fun () ->
    match Kafka_service.config_of_env () with
    | Ok _ -> Alcotest.fail "an unstated transport posture must not default to plaintext"
    | Error e ->
      Alcotest.(check bool)
        "names the variable"
        true
        (contains (Kafka_service.error_to_string e) "KAFKA_SECURITY_PROTOCOL"));
  with_kafka_env (fun () ->
    Alcotest.(check bool)
      "stated plaintext is accepted"
      true
      (Result.is_ok (Kafka_service.config_of_env ())))
;;

let test_config_of_env_requires_addresses () =
  with_kafka_env
  @@ fun () ->
  Alcotest.(check bool)
    "all stated is accepted"
    true
    (Result.is_ok (Kafka_service.config_of_env ()));
  List.iter
    (fun missing ->
       with_env missing "" (fun () ->
         match Kafka_service.config_of_env () with
         | Ok _ -> Alcotest.failf "expected an unset %s to be an error" missing
         | Error e ->
           Alcotest.(check bool)
             ("names " ^ missing)
             true
             (contains (Kafka_service.error_to_string e) missing)))
    [ "KAFKA_BROKERS"; "SCHEMA_REGISTRY_URL"; "REDPANDA_ADMIN_URL" ];
  with_env "KAFKA_BROKERS" "" (fun () ->
    with_env "REDPANDA_ADMIN_URL" "" (fun () ->
      match Kafka_service.config_of_env () with
      | Ok _ -> Alcotest.fail "expected two unset addresses to be an error"
      | Error e ->
        let msg = Kafka_service.error_to_string e in
        Alcotest.(check bool)
          "names both"
          true
          (contains msg "KAFKA_BROKERS" && contains msg "REDPANDA_ADMIN_URL")))
;;

let test_config_of_env_topic_durability () =
  with_kafka_env
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

let raw_source_msg ?(headers = []) ?key () : Kafka.Consumer.message =
  { topic = "orders"
  ; partition = 0l
  ; offset = 0L
  ; key
  ; value = Some (Bytes.of_string "payload")
  ; timestamp = None
  ; headers
  }
;;

let test_decode_error_routes_to_dlq_and_acks_after_publish () =
  let acked = ref 0 in
  let published = ref None in
  let raw_msg =
    raw_source_msg
      ~key:(Bytes.of_string "order-42")
      ~headers:[ "app-header", Some "kept" ]
      ()
  in
  let publish ~target_topic (msg : Kafka_service.Dlq.relay) =
    published := Some (target_topic, msg, !acked);
    Ok ()
  in
  let ack () =
    incr acked;
    Ok ()
  in
  match
    Kafka_service.Dlq.route_decode_error
      ~dlq_topic:"orders-dlq"
      ~raw_msg
      ~decode_error:"bad json"
      ~group_id:"test-group"
      ~publish
      ~ack
  with
  | Error e -> Alcotest.failf "unexpected route error: %s" (Kafka.Error.to_string e)
  | Ok () ->
    Alcotest.(check int) "acked once" 1 !acked;
    (match !published with
     | None -> Alcotest.fail "publish was never called"
     | Some (target_topic, (msg : Kafka_service.Dlq.relay), acked_before) ->
       Alcotest.(check string) "target" "orders-dlq" target_topic;
       Alcotest.(check (option string))
         "raw payload preserved"
         (Some "payload")
         (Option.map Bytes.to_string msg.source.Kafka.Consumer.value);
       Alcotest.(check (option string))
         "key preserved"
         (Some "order-42")
         (Option.map Bytes.to_string msg.source.Kafka.Consumer.key);
       Alcotest.(check (option string))
         "the application's own header is carried through"
         (Some "kept")
         (List.assoc_opt "app-header" msg.headers |> Option.join);
       Alcotest.(check (option string))
         "decode diagnostic header"
         (Some "bad json")
         (List.assoc_opt "X-Sol-Decode-Error" msg.headers |> Option.join);
       Alcotest.(check (option string))
         "origin-group header (BUG-030)"
         (Some "test-group")
         (List.assoc_opt "X-Sol-Origin-Group" msg.headers |> Option.join);
       Alcotest.(check int) "publish happened before ack" 0 acked_before)
;;

let test_decode_error_publish_failure_does_not_ack () =
  let acked = ref false in
  let publish ~target_topic:_ (_ : Kafka_service.Dlq.relay) =
    Error Kafka.Error.Transport
  in
  let ack () =
    acked := true;
    Ok ()
  in
  match
    Kafka_service.Dlq.route_decode_error
      ~dlq_topic:"orders-dlq"
      ~raw_msg:(raw_source_msg ())
      ~decode_error:"bad json"
      ~group_id:"test-group"
      ~publish
      ~ack
  with
  | Error Kafka.Error.Transport -> Alcotest.(check bool) "ack skipped" false !acked
  | _ -> Alcotest.fail "expected publish failure to be returned"
;;

let hash12 s = String.sub (Digest.to_hex (Digest.string s)) 0 12
let dlq ~source ~group_id = Kafka_service.Dlq.dlq_topic_name ~source ~group_id

let test_dlq_topic_name_scopes_by_group () =
  Alcotest.(check string)
    "readable group prefix plus a collision-resistant hash"
    ("orders.payments-" ^ hash12 "payments" ^ ".dlq")
    (dlq ~source:"orders" ~group_id:"payments");
  Alcotest.(check bool)
    "two groups on the same source topic get distinct topic names"
    true
    (not
       (String.equal
          (dlq ~source:"orders" ~group_id:"payments")
          (dlq ~source:"orders" ~group_id:"analytics")))
;;

let test_dlq_topic_name_sanitizes_invalid_characters () =
  Alcotest.(check string)
    "dots and slashes become hyphens"
    ("orders.pay-ments-v1-eu-west-1-" ^ hash12 "pay.ments/v1_eu:west-1" ^ ".dlq")
    (dlq ~source:"orders" ~group_id:"pay.ments/v1_eu:west-1")
;;

let test_dlq_topic_name_distinguishes_punctuation_variants () =
  let variants = [ "pay.ments"; "pay_ments"; "pay-ments" ] in
  let names = List.map (fun group_id -> dlq ~source:"orders" ~group_id) variants in
  Alcotest.(check int)
    "every punctuation variant gets its own topic"
    3
    (List.length (List.sort_uniq String.compare names));
  Alcotest.(check bool)
    "each variant is deterministic (one topic per group)"
    true
    (List.for_all2
       (fun group_id name -> String.equal name (dlq ~source:"orders" ~group_id))
       variants
       names);
  Alcotest.(check bool)
    "the readable prefix is retained"
    true
    (String.starts_with ~prefix:"orders.pay-ments-" (List.hd names))
;;

let test_dlq_topic_name_empty_group_id_is_unscoped () =
  Alcotest.(check string)
    "empty group id"
    ("orders.unscoped-" ^ hash12 "" ^ ".dlq")
    (dlq ~source:"orders" ~group_id:"")
;;

let test_dlq_topic_name_truncates_overlong_group_ids_deterministically () =
  let long_group = String.make 200 'g' in
  let name1 = dlq ~source:"orders" ~group_id:long_group in
  let name2 = dlq ~source:"orders" ~group_id:long_group in
  Alcotest.(check string) "deterministic for the same group id" name1 name2;
  Alcotest.(check bool)
    "stays well under Kafka's 249-byte limit"
    true
    (String.length name1 < 249);
  Alcotest.(check bool)
    "the group segment stays within the bound"
    true
    (String.length name1 <= String.length "orders" + 1 + 64 + 1 + 4);
  let other_long_group = String.make 200 'h' in
  let name3 = dlq ~source:"orders" ~group_id:other_long_group in
  Alcotest.(check bool)
    "two different overlong group ids never truncate to the same name"
    true
    (not (String.equal name1 name3))
;;

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
        ; test_case "addresses are required" `Quick test_config_of_env_requires_addresses
        ] )
    ; ( "dlq"
      , [ test_case
            "decode error routes to dlq and acks after publish"
            `Quick
            test_decode_error_routes_to_dlq_and_acks_after_publish
        ; test_case
            "decode error publish failure does not ack"
            `Quick
            test_decode_error_publish_failure_does_not_ack
        ; test_case
            "dlq topic name scopes by group"
            `Quick
            test_dlq_topic_name_scopes_by_group
        ; test_case
            "dlq topic name sanitizes invalid characters"
            `Quick
            test_dlq_topic_name_sanitizes_invalid_characters
        ; test_case
            "dlq topic name isolates punctuation variants (BUG-080)"
            `Quick
            test_dlq_topic_name_distinguishes_punctuation_variants
        ; test_case
            "dlq topic name: empty group id is unscoped"
            `Quick
            test_dlq_topic_name_empty_group_id_is_unscoped
        ; test_case
            "dlq topic name truncates overlong group ids deterministically"
            `Quick
            test_dlq_topic_name_truncates_overlong_group_ids_deterministically
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
