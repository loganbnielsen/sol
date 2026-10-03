type compatibility = Confluent_registry.compatibility =
  | Compatible
  | Incompatible
  | No_schema_registered

module Schema = struct
  let check ~net ~clock ~registry_url (module M : Kafka_service_intf.MESSAGE) =
    let topic_name = Kafka_service_intf.topic_name_to_string M.topic_name in
    match
      Confluent_registry.check_compatibility
        net
        ~clock
        ~registry_url
        ~topic_name
        ~schema:M.schema
    with
    | Error _ as err -> err
    | Ok (Compatible | No_schema_registered) -> Ok ()
    | Ok Incompatible ->
      Error
        (Printf.sprintf
           "schema for topic '%s' is not compatible with the registered version"
           topic_name)
  ;;

  let check_all ~net ~clock ~registry_url modules =
    List.fold_left
      (fun acc m ->
         match acc with
         | Error _ as e -> e
         | Ok () -> check ~net ~clock ~registry_url m)
      (Ok ())
      modules
  ;;
end

let register_contract net ~clock ~registry_url ~topic_name ~schema =
  let open Result.Syntax in
  let* () =
    Confluent_registry.set_subject_compatibility net ~clock ~registry_url ~topic_name
  in
  Confluent_registry.register_schema net ~clock ~registry_url ~topic_name ~schema
;;

let decode_message topic raw_msg =
  let open Result.Syntax in
  let raw_bytes = raw_msg.Kafka.Consumer.value in
  let string_headers =
    List.filter_map
      (fun (k, v) -> Option.map (fun v -> k, v) v)
      raw_msg.Kafka.Consumer.headers
  in
  let trace_ctx = Obs_trace.extract_from_headers string_headers in
  let result =
    let* raw_bytes =
      Option.to_result raw_bytes ~none:"wire format: tombstone (message has no value)"
    in
    let* _schema_id, json_str = Confluent_registry.Wire.decode raw_bytes in
    let* json =
      try Ok (Yojson.Safe.from_string json_str) with
      | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
      | exn -> Error ("json parse: " ^ Printexc.to_string exn)
    in
    topic.Kafka_service_intf.decode json
    |> Result.map_error (fun e -> "message decode: " ^ e)
  in
  match result with
  | Ok msg -> Ok (msg, trace_ctx)
  | Error e -> Error (e, raw_bytes)
;;
