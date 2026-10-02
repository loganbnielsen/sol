let test_wire_roundtrip () =
  let json = `Assoc [ "amount", `Int 100; "currency", `String "USD" ] in
  let schema_id = 42 in
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id json in
  match Kafka_service.Confluent_wire.decode encoded with
  | Error e -> Windtrap.failf "decode failed: %s" e
  | Ok (got_id, json_str) ->
    Windtrap.equal Windtrap.int ~msg:"schema id roundtrips" schema_id got_id;
    let decoded = Yojson.Safe.from_string json_str in
    Windtrap.equal
      Windtrap.string
      ~msg:"json roundtrips"
      (Yojson.Safe.to_string json)
      (Yojson.Safe.to_string decoded)
;;

let test_wire_large_schema_id () =
  let schema_id = 0x00FFFFFF in
  let json = `String "hello" in
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id json in
  match Kafka_service.Confluent_wire.decode encoded with
  | Error e -> Windtrap.failf "decode failed: %s" e
  | Ok (got_id, _) ->
    Windtrap.equal Windtrap.int ~msg:"large schema id roundtrips" schema_id got_id
;;

let test_wire_bad_magic () =
  let bad = Bytes.of_string "\x01\x00\x00\x00\x01{}" in
  Windtrap.equal
    Windtrap.bool
    ~msg:"bad magic returns error"
    true
    (Result.is_error (Kafka_service.Confluent_wire.decode bad))
;;

let test_wire_too_short () =
  let bad = Bytes.of_string "\x00\x00" in
  Windtrap.equal
    Windtrap.bool
    ~msg:"too short returns error"
    true
    (Result.is_error (Kafka_service.Confluent_wire.decode bad))
;;

let test_wire_magic_byte () =
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id:1 (`String "x") in
  Windtrap.equal Windtrap.char ~msg:"magic byte is 0x00" '\x00' (Bytes.get encoded 0)
;;

let test_wire_schema_id_big_endian () =
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id:0x01020304 (`String "x") in
  Windtrap.equal Windtrap.char ~msg:"byte 1" '\x01' (Bytes.get encoded 1);
  Windtrap.equal Windtrap.char ~msg:"byte 2" '\x02' (Bytes.get encoded 2);
  Windtrap.equal Windtrap.char ~msg:"byte 3" '\x03' (Bytes.get encoded 3);
  Windtrap.equal Windtrap.char ~msg:"byte 4" '\x04' (Bytes.get encoded 4)
;;

let check_uri msg ~expected_host ~expected_port ~expected_scheme url =
  let u = Uri.of_string url in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:(msg ^ " host")
    (Some expected_host)
    (Uri.host u);
  Windtrap.equal
    (Windtrap.option Windtrap.int)
    ~msg:(msg ^ " port")
    expected_port
    (Uri.port u);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:(msg ^ " scheme")
    (Some expected_scheme)
    (Uri.scheme u)
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
    | Ok _ -> Windtrap.fail "expected invalid security protocol to fail"
    | Error e ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"clear env protocol error"
        true
        (contains (Kafka_service.error_to_string e) "KAFKA_SECURITY_PROTOCOL"))
;;

let test_config_of_env_requires_security_protocol () =
  with_kafka_env
  @@ fun () ->
  with_env "KAFKA_SECURITY_PROTOCOL" "" (fun () ->
    match Kafka_service.config_of_env () with
    | Ok _ -> Windtrap.fail "an unstated transport posture must not default to plaintext"
    | Error e ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the variable"
        true
        (contains (Kafka_service.error_to_string e) "KAFKA_SECURITY_PROTOCOL"));
  with_kafka_env (fun () ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"stated plaintext is accepted"
      true
      (Result.is_ok (Kafka_service.config_of_env ())))
;;

let test_config_of_env_requires_addresses () =
  with_kafka_env
  @@ fun () ->
  Windtrap.equal
    Windtrap.bool
    ~msg:"all stated is accepted"
    true
    (Result.is_ok (Kafka_service.config_of_env ()));
  List.iter
    (fun missing ->
       with_env missing "" (fun () ->
         match Kafka_service.config_of_env () with
         | Ok _ -> Windtrap.failf "expected an unset %s to be an error" missing
         | Error e ->
           Windtrap.equal
             Windtrap.bool
             ~msg:("names " ^ missing)
             true
             (contains (Kafka_service.error_to_string e) missing)))
    [ "KAFKA_BROKERS"; "SCHEMA_REGISTRY_URL"; "REDPANDA_ADMIN_URL" ];
  with_env "KAFKA_BROKERS" "" (fun () ->
    with_env "REDPANDA_ADMIN_URL" "" (fun () ->
      match Kafka_service.config_of_env () with
      | Ok _ -> Windtrap.fail "expected two unset addresses to be an error"
      | Error e ->
        let msg = Kafka_service.error_to_string e in
        Windtrap.equal
          Windtrap.bool
          ~msg:"names both"
          true
          (contains msg "KAFKA_BROKERS" && contains msg "REDPANDA_ADMIN_URL")))
;;

let test_config_of_env_topic_durability () =
  with_kafka_env
  @@ fun () ->
  with_env "SOL_KAFKA_DURABILITY" "single-broker-loss" (fun () ->
    match Kafka_service.config_of_env () with
    | Error e -> Windtrap.fail (Kafka_service.error_to_string e)
    | Ok config ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"semantic policy"
        true
        (config.topic_durability = Kafka_service.Single_broker_loss));
  with_env "SOL_KAFKA_DURABILITY" "unsupported" (fun () ->
    match Kafka_service.config_of_env () with
    | Ok _ -> Windtrap.fail "expected invalid durability policy to fail"
    | Error e ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"clear durability error"
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
  | Error e -> Windtrap.failf "unexpected route error: %s" (Kafka.Error.to_string e)
  | Ok () ->
    Windtrap.equal Windtrap.int ~msg:"acked once" 1 !acked;
    (match !published with
     | None -> Windtrap.fail "publish was never called"
     | Some (target_topic, (msg : Kafka_service.Dlq.relay), acked_before) ->
       Windtrap.equal Windtrap.string ~msg:"target" "orders-dlq" target_topic;
       Windtrap.equal
         (Windtrap.option Windtrap.string)
         ~msg:"raw payload preserved"
         (Some "payload")
         (Option.map Bytes.to_string msg.source.Kafka.Consumer.value);
       Windtrap.equal
         (Windtrap.option Windtrap.string)
         ~msg:"key preserved"
         (Some "order-42")
         (Option.map Bytes.to_string msg.source.Kafka.Consumer.key);
       Windtrap.equal
         (Windtrap.option Windtrap.string)
         ~msg:"the application's own header is carried through"
         (Some "kept")
         (List.assoc_opt "app-header" msg.headers |> Option.join);
       Windtrap.equal
         (Windtrap.option Windtrap.string)
         ~msg:"decode diagnostic header"
         (Some "bad json")
         (List.assoc_opt "X-Sol-Decode-Error" msg.headers |> Option.join);
       Windtrap.equal
         (Windtrap.option Windtrap.string)
         ~msg:"origin-group header (BUG-030)"
         (Some "test-group")
         (List.assoc_opt "X-Sol-Origin-Group" msg.headers |> Option.join);
       Windtrap.equal Windtrap.int ~msg:"publish happened before ack" 0 acked_before)
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
  | Error Kafka.Error.Transport ->
    Windtrap.equal Windtrap.bool ~msg:"ack skipped" false !acked
  | _ -> Windtrap.fail "expected publish failure to be returned"
;;

let hash12 s = String.sub (Digest.to_hex (Digest.string s)) 0 12
let dlq ~source ~group_id = Kafka_service.Dlq.dlq_topic_name ~source ~group_id

let test_dlq_topic_name_scopes_by_group () =
  Windtrap.equal
    Windtrap.string
    ~msg:"readable group prefix plus a collision-resistant hash"
    ("orders.payments-" ^ hash12 "payments" ^ ".dlq")
    (dlq ~source:"orders" ~group_id:"payments");
  Windtrap.equal
    Windtrap.bool
    ~msg:"two groups on the same source topic get distinct topic names"
    true
    (not
       (String.equal
          (dlq ~source:"orders" ~group_id:"payments")
          (dlq ~source:"orders" ~group_id:"analytics")))
;;

let test_dlq_topic_name_sanitizes_invalid_characters () =
  Windtrap.equal
    Windtrap.string
    ~msg:"dots and slashes become hyphens"
    ("orders.pay-ments-v1-eu-west-1-" ^ hash12 "pay.ments/v1_eu:west-1" ^ ".dlq")
    (dlq ~source:"orders" ~group_id:"pay.ments/v1_eu:west-1")
;;

let test_dlq_topic_name_distinguishes_punctuation_variants () =
  let variants = [ "pay.ments"; "pay_ments"; "pay-ments" ] in
  let names = List.map (fun group_id -> dlq ~source:"orders" ~group_id) variants in
  Windtrap.equal
    Windtrap.int
    ~msg:"every punctuation variant gets its own topic"
    3
    (List.length (List.sort_uniq String.compare names));
  Windtrap.equal
    Windtrap.bool
    ~msg:"each variant is deterministic (one topic per group)"
    true
    (List.for_all2
       (fun group_id name -> String.equal name (dlq ~source:"orders" ~group_id))
       variants
       names);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the readable prefix is retained"
    true
    (String.starts_with ~prefix:"orders.pay-ments-" (List.hd names))
;;

let test_dlq_topic_name_empty_group_id_is_unscoped () =
  Windtrap.equal
    Windtrap.string
    ~msg:"empty group id"
    ("orders.unscoped-" ^ hash12 "" ^ ".dlq")
    (dlq ~source:"orders" ~group_id:"")
;;

let test_dlq_topic_name_truncates_overlong_group_ids_deterministically () =
  let long_group = String.make 200 'g' in
  let name1 = dlq ~source:"orders" ~group_id:long_group in
  let name2 = dlq ~source:"orders" ~group_id:long_group in
  Windtrap.equal Windtrap.string ~msg:"deterministic for the same group id" name1 name2;
  Windtrap.equal
    Windtrap.bool
    ~msg:"stays well under Kafka's 249-byte limit"
    true
    (String.length name1 < 249);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the group segment stays within the bound"
    true
    (String.length name1 <= String.length "orders" + 1 + 64 + 1 + 4);
  let other_long_group = String.make 200 'h' in
  let name3 = dlq ~source:"orders" ~group_id:other_long_group in
  Windtrap.equal
    Windtrap.bool
    ~msg:"two different overlong group ids never truncate to the same name"
    true
    (not (String.equal name1 name3))
;;

let test_topic_name_accepts_kafka_compatible_names () =
  let check name =
    match Kafka_service.topic_name name with
    | Ok topic ->
      Windtrap.equal
        Windtrap.string
        ~msg:name
        name
        (Kafka_service.topic_name_to_string topic)
    | Error e ->
      Windtrap.failf "%s should be valid: %s" name (Kafka_service.error_to_string e)
  in
  List.iter
    check
    [ "orders"; "sol-demo-orders"; "payments.charges_v1"; "__consumer_offsets" ]
;;

let test_topic_name_rejects_invalid_names () =
  let long_name = String.make 250 'a' in
  let check name =
    match Kafka_service.topic_name name with
    | Ok _ -> Windtrap.failf "%S should be invalid" name
    | Error _ -> ()
  in
  List.iter check [ ""; "."; ".."; "orders/v1"; "orders v1"; long_name ]
;;

let result_error () =
  Windtrap.testable
    ~pp:(fun fmt -> function
       | Ok _ -> Format.fprintf fmt "Ok _"
       | Error e -> Format.fprintf fmt "Error %S" e)
    ()
;;

let test_decode_compatibility_response () =
  match Kafka_service.Schema.decode_compatibility_response {|{"is_compatible":true}|} with
  | Ok response ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"is compatible"
      true
      response.Kafka_service.Schema.is_compatible
  | Error e -> Windtrap.failf "decode failed: %s" e
;;

let test_is_subject_not_found () =
  let yes body = Kafka_service.Schema.is_subject_not_found body in
  Windtrap.equal
    Windtrap.bool
    ~msg:"40401"
    true
    (yes {|{"error_code":40401,"message":"Subject not found."}|});
  Windtrap.equal
    Windtrap.bool
    ~msg:"40402"
    true
    (yes {|{"error_code":40402,"message":"Version not found."}|});
  Windtrap.equal
    Windtrap.bool
    ~msg:"plain 404 (wrong path)"
    false
    (yes {|{"error_code":404,"message":"HTTP 404 Not Found"}|});
  Windtrap.equal Windtrap.bool ~msg:"non-JSON 404" false (yes "<html>404</html>");
  Windtrap.equal Windtrap.bool ~msg:"empty" false (yes "")
;;

let test_decode_compatibility_response_errors () =
  Windtrap.equal
    (result_error ())
    ~msg:"missing field"
    (Error {|unexpected registry response: {"ok":true}|})
    (Kafka_service.Schema.decode_compatibility_response {|{"ok":true}|});
  Windtrap.equal
    (result_error ())
    ~msg:"malformed json"
    (Error {|json parse error in registry response: {"is_compatible":|})
    (Kafka_service.Schema.decode_compatibility_response {|{"is_compatible":|})
;;

let test_decode_registration_response () =
  match Kafka_service.Schema.decode_registration_response {|{"id":42}|} with
  | Ok response ->
    Windtrap.equal Windtrap.int ~msg:"schema id" 42 response.Kafka_service.Schema.id
  | Error e -> Windtrap.failf "decode failed: %s" e
;;

let test_decode_registration_response_errors () =
  Windtrap.equal
    (result_error ())
    ~msg:"missing id"
    (Error {|schema registry: missing 'id' in: {"schema":{}}|})
    (Kafka_service.Schema.decode_registration_response {|{"schema":{}}|});
  Windtrap.equal
    (result_error ())
    ~msg:"unexpected shape"
    (Error {|schema registry: unexpected response: []|})
    (Kafka_service.Schema.decode_registration_response {|[]|});
  Windtrap.equal
    (result_error ())
    ~msg:"malformed json"
    (Error {|schema registry: json parse error in: {"id":|})
    (Kafka_service.Schema.decode_registration_response {|{"id":|})
;;

let test_decode_topic_partitions () =
  match
    Kafka_service.Admin.decode_topic_partitions
      {|[{"partition_id":0,"replicas":[{"node_id":0},{"node_id":1},{"node_id":2}]},{"partition_id":1,"replicas":[{"node_id":1},{"node_id":2},{"node_id":0}]}]|}
  with
  | Ok (Kafka_service.Admin.Topic_partitions { partitions; replication_factor }) ->
    Windtrap.equal Windtrap.int ~msg:"partition count" 2 partitions;
    Windtrap.equal Windtrap.int ~msg:"replication factor" 3 replication_factor
  | Ok Kafka_service.Admin.Topic_not_found ->
    Windtrap.fail "decoder should not return Topic_not_found for HTTP 200"
  | Error e ->
    Windtrap.failf
      "decode failed: %s"
      (Kafka_service.Admin.topic_partition_error_to_string e)
;;

let test_decode_topic_partitions_errors () =
  let check_error name body =
    match Kafka_service.Admin.decode_topic_partitions body with
    | Ok _ -> Windtrap.failf "%s: expected malformed response" name
    | Error e ->
      Windtrap.equal
        Windtrap.string
        ~msg:name
        ("malformed admin API topic response: " ^ body)
        (Kafka_service.Admin.topic_partition_error_to_string e)
  in
  check_error "object instead of list" {|{"name":"orders"}|};
  check_error "missing replicas" {|[{"partition_id":0}]|};
  check_error "empty partitions" {|[]|};
  check_error "malformed json" {|[{"partition_id":|}
;;

let () =
  let open Windtrap in
  run
    "kafka_service"
    [ Windtrap.group
        "wire_format"
        [ test "roundtrip" test_wire_roundtrip
        ; test "large schema id" test_wire_large_schema_id
        ; test "bad magic byte" test_wire_bad_magic
        ; test "too short" test_wire_too_short
        ; test "magic byte is 0x00" test_wire_magic_byte
        ; test "schema id big-endian" test_wire_schema_id_big_endian
        ]
    ; Windtrap.group
        "url_parser"
        [ test "parse base url" test_parse_url
        ; test "https:// tls=true" test_parse_url_https
        ]
    ; Windtrap.group
        "config"
        [ test
            "unknown security protocol fails clearly"
            test_config_of_env_rejects_unknown_security_protocol
        ; test
            "requires KAFKA_SECURITY_PROTOCOL"
            test_config_of_env_requires_security_protocol
        ; test "topic durability" test_config_of_env_topic_durability
        ; test "addresses are required" test_config_of_env_requires_addresses
        ]
    ; Windtrap.group
        "dlq"
        [ test
            "decode error routes to dlq and acks after publish"
            test_decode_error_routes_to_dlq_and_acks_after_publish
        ; test
            "decode error publish failure does not ack"
            test_decode_error_publish_failure_does_not_ack
        ; test "dlq topic name scopes by group" test_dlq_topic_name_scopes_by_group
        ; test
            "dlq topic name sanitizes invalid characters"
            test_dlq_topic_name_sanitizes_invalid_characters
        ; test
            "dlq topic name isolates punctuation variants (BUG-080)"
            test_dlq_topic_name_distinguishes_punctuation_variants
        ; test
            "dlq topic name: empty group id is unscoped"
            test_dlq_topic_name_empty_group_id_is_unscoped
        ; test
            "dlq topic name truncates overlong group ids deterministically"
            test_dlq_topic_name_truncates_overlong_group_ids_deterministically
        ]
    ; Windtrap.group
        "topic_name"
        [ test
            "accepts Kafka-compatible names"
            test_topic_name_accepts_kafka_compatible_names
        ; test "rejects invalid names" test_topic_name_rejects_invalid_names
        ]
    ; Windtrap.group
        "schema_registry_decoding"
        [ test "compatibility response" test_decode_compatibility_response
        ; test "compatibility response errors" test_decode_compatibility_response_errors
        ; test "is_subject_not_found (BUG-049)" test_is_subject_not_found
        ; test "registration response" test_decode_registration_response
        ; test "registration response errors" test_decode_registration_response_errors
        ]
    ; Windtrap.group
        "admin_topic_metadata"
        [ test "topic partitions" test_decode_topic_partitions
        ; test "topic partition errors" test_decode_topic_partitions_errors
        ]
    ]
;;
