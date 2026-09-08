type compatibility_response =
  { is_compatible : bool
  }

type registration_response =
  { id : int
  }

let decode_json ~parse_error resp_body =
  try Ok (Yojson.Safe.from_string resp_body)
  with Yojson.Json_error _ -> Error (parse_error resp_body)

let decode_compatibility_response resp_body =
  let ( let* ) = Result.bind in
  let* json =
    decode_json
      ~parse_error:(fun body ->
        "json parse error in registry response: " ^ body)
      resp_body
  in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "is_compatible" fields with
     | Some (`Bool is_compatible) -> Ok { is_compatible }
     | _ -> Error ("unexpected registry response: " ^ resp_body))
  | _ -> Error ("unexpected registry response: " ^ resp_body)

let decode_registration_response resp_body =
  let ( let* ) = Result.bind in
  let* json =
    decode_json
      ~parse_error:(fun body ->
        "schema registry: json parse error in: " ^ body)
      resp_body
  in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "id" fields with
     | Some (`Int id) -> Ok { id }
     | _ -> Error ("schema registry: missing 'id' in: " ^ resp_body))
  | _ -> Error ("schema registry: unexpected response: " ^ resp_body)

module Schema = struct
  let check ~net ~clock ~registry_url (module M : Kafka_service_intf.MESSAGE) =
    let topic_name = Kafka_service_intf.topic_name_to_string M.topic_name in
    let subject = topic_name ^ "-value" in
    let body = Yojson.Safe.to_string (`Assoc [
      ("schemaType", `String "JSON");
      ("schema",     `String M.schema);
    ]) in
    match Kafka_service_http.http_post net ~clock ~base_url:registry_url
            ~path:(Printf.sprintf "/compatibility/subjects/%s/versions/latest" subject)
            ~content_type:"application/vnd.schemaregistry.v1+json"
            ~body with
    | Error e -> Error ("connection failed: " ^ e)
    | Ok (200, resp_body) ->
      (match decode_compatibility_response resp_body with
       | Error _ as err -> err
       | Ok { is_compatible = true } -> Ok ()
       | Ok { is_compatible = false } ->
         Error (Printf.sprintf
           "schema for topic '%s' is not compatible with the registered version"
           topic_name))
    | Ok (404, _) ->
      Ok ()
    | Ok (status, body) ->
      Error (Printf.sprintf "schema registry HTTP %d: %s" status body)

  let check_all ~net ~clock ~registry_url modules =
    List.fold_left (fun acc m ->
      match acc with
      | Error _ as e -> e
      | Ok ()        -> check ~net ~clock ~registry_url m
    ) (Ok ()) modules
end

let set_subject_compatibility net ~clock ~registry_url ~topic_name =

  let subject = topic_name ^ "-value" in
  let body = {|{"compatibility":"FULL"}|} in
  match Kafka_service_http.http_put net ~clock ~base_url:registry_url
          ~path:(Printf.sprintf "/config/%s" subject)
          ~content_type:"application/vnd.schemaregistry.v1+json"
          ~body with
  | Error e -> Error ("set compatibility: " ^ e)
  | Ok (200, _) | Ok (204, _) -> Ok ()
  | Ok (status, resp_body) ->
    Error (Printf.sprintf "set compatibility: HTTP %d: %s" status resp_body)

let register_schema net ~clock ~registry_url ~topic_name ~schema =

  let subject = topic_name ^ "-value" in
  let body =
    Yojson.Safe.to_string (`Assoc [
      ("schemaType", `String "JSON");
      ("schema",     `String schema);
    ])
  in
  match Kafka_service_http.http_post net ~clock ~base_url:registry_url
          ~path:(Printf.sprintf "/subjects/%s/versions" subject)
          ~content_type:"application/vnd.schemaregistry.v1+json"
          ~body with
  | Error e -> Error ("schema registry connect: " ^ e)
  | Ok (status, resp_body) when status = 200 || status = 201 ->
    (match decode_registration_response resp_body with
     | Ok { id } -> Ok id
     | Error _ as err -> err)
  | Ok (status, resp_body) ->
    Error (Printf.sprintf "schema registry: HTTP %d: %s" status resp_body)

module Confluent_wire = struct
  let header_len = 5
  let magic_byte = '\x00'

  let encode ~schema_id json =
    let json_str = Yojson.Safe.to_string json in
    let json_len = String.length json_str in
    let cs = Cstruct.create (header_len + json_len) in
    Cstruct.set_char cs 0 magic_byte;
    Cstruct.BE.set_uint32 cs 1 (Int32.of_int schema_id);
    Cstruct.blit_from_string json_str 0 cs header_len json_len;
    Cstruct.to_bytes cs

  let decode bytes =
    if Bytes.length bytes < header_len then
      Error "wire format: message too short"
    else
      let cs = Cstruct.of_bytes bytes in
      if Cstruct.get_char cs 0 <> magic_byte then
        Error "wire format: invalid magic byte"
      else
        let schema_id = Int32.to_int (Cstruct.BE.get_uint32 cs 1) in
        let json_str = Cstruct.(to_string (sub cs header_len (length cs - header_len))) in
        Ok (schema_id, json_str)
end

let encode_wire ~schema_id json = Confluent_wire.encode ~schema_id json
let decode_wire bytes = Confluent_wire.decode bytes

let decode_message topic raw_msg =
  let ( let* ) = Result.bind in
  let raw_bytes = raw_msg.Kafka.Consumer.value in
  let string_headers =
    List.filter_map
      (fun (k, v) -> Option.map (fun v -> (k, v)) v)
      raw_msg.Kafka.Consumer.headers
  in
  let trace_ctx = Obs_trace.extract_from_headers string_headers in
  let result =
    let* raw_bytes =
      Option.to_result raw_bytes ~none:"wire format: tombstone (message has no value)"
    in
    let* (_schema_id, json_str) = decode_wire raw_bytes in
    let* json =
      (try Ok (Yojson.Safe.from_string json_str)
       with
       | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
       | exn -> Error ("json parse: " ^ Printexc.to_string exn))
    in
    topic.Kafka_service_intf.decode json
    |> Result.map_error (fun e -> "message decode: " ^ e)
  in
  match result with
  | Ok msg  -> Ok (msg, trace_ctx)
  | Error e -> Error (e, raw_bytes)
