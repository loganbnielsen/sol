type compatibility_response = { is_compatible : bool }
type registration_response = { id : int }

let decode_json ~parse_error resp_body =
  try Ok (Yojson.Safe.from_string resp_body) with
  | Yojson.Json_error _ -> Error (parse_error resp_body)
;;

let decode_compatibility_response resp_body =
  let open Result.Syntax in
  let* json =
    decode_json
      ~parse_error:(fun body -> "json parse error in registry response: " ^ body)
      resp_body
  in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "is_compatible" fields with
     | Some (`Bool is_compatible) -> Ok { is_compatible }
     | _ -> Error ("unexpected registry response: " ^ resp_body))
  | _ -> Error ("unexpected registry response: " ^ resp_body)
;;

let decode_registration_response resp_body =
  let open Result.Syntax in
  let* json =
    decode_json
      ~parse_error:(fun body -> "schema registry: json parse error in: " ^ body)
      resp_body
  in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "id" fields with
     | Some (`Int id) -> Ok { id }
     | _ -> Error ("schema registry: missing 'id' in: " ^ resp_body))
  | _ -> Error ("schema registry: unexpected response: " ^ resp_body)
;;

let subject_name topic_name = topic_name ^ "-value"

let is_subject_not_found body =
  match Yojson.Safe.from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "error_code" fields with
     | Some (`Int (40401 | 40402)) -> true
     | _ -> false)
  | _ -> false
  | exception Yojson.Json_error _ -> false
;;

type compatibility =
  | Compatible
  | Incompatible
  | No_schema_registered

let check_compatibility ?ca_file net ~clock ~registry_url ~topic_name ~schema =
  let subject = subject_name topic_name in
  let body =
    Yojson.Safe.to_string
      (`Assoc [ "schemaType", `String "JSON"; "schema", `String schema ])
  in
  match
    Kafka_service_http.http_post
      ?ca_file
      net
      ~clock
      ~base_url:registry_url
      ~path:(Printf.sprintf "/compatibility/subjects/%s/versions/latest" subject)
      ~content_type:"application/vnd.schemaregistry.v1+json"
      ~body
  with
  | Error e -> Error ("connection failed: " ^ e)
  | Ok (200, resp_body) ->
    (match decode_compatibility_response resp_body with
     | Error _ as err -> err
     | Ok { is_compatible = true } -> Ok Compatible
     | Ok { is_compatible = false } -> Ok Incompatible)
  | Ok (404, body) when is_subject_not_found body -> Ok No_schema_registered
  | Ok (404, body) ->
    Error
      (Printf.sprintf
         "schema registry HTTP 404 that is not 'subject not found' (is %s the registry's \
          base URL?): %s"
         registry_url
         body)
  | Ok (status, body) -> Error (Printf.sprintf "schema registry HTTP %d: %s" status body)
;;

let set_subject_compatibility ?ca_file net ~clock ~registry_url ~topic_name =
  let subject = subject_name topic_name in
  let body = {|{"compatibility":"FULL"}|} in
  match
    Kafka_service_http.http_put
      ?ca_file
      net
      ~clock
      ~base_url:registry_url
      ~path:(Printf.sprintf "/config/%s" subject)
      ~content_type:"application/vnd.schemaregistry.v1+json"
      ~body
  with
  | Error e -> Error ("set compatibility: " ^ e)
  | Ok (200, _) | Ok (204, _) -> Ok ()
  | Ok (status, resp_body) ->
    Error (Printf.sprintf "set compatibility: HTTP %d: %s" status resp_body)
;;

let register_schema ?ca_file net ~clock ~registry_url ~topic_name ~schema =
  let subject = subject_name topic_name in
  let body =
    Yojson.Safe.to_string
      (`Assoc [ "schemaType", `String "JSON"; "schema", `String schema ])
  in
  match
    Kafka_service_http.http_post
      ?ca_file
      net
      ~clock
      ~base_url:registry_url
      ~path:(Printf.sprintf "/subjects/%s/versions" subject)
      ~content_type:"application/vnd.schemaregistry.v1+json"
      ~body
  with
  | Error e -> Error ("schema registry connect: " ^ e)
  | Ok (status, resp_body) when status = 200 || status = 201 ->
    (match decode_registration_response resp_body with
     | Ok { id } -> Ok id
     | Error _ as err -> err)
  | Ok (status, resp_body) ->
    Error (Printf.sprintf "schema registry: HTTP %d: %s" status resp_body)
;;

let lookup_schema ?ca_file net ~clock ~registry_url ~topic_name ~schema =
  let subject = subject_name topic_name in
  let body =
    Yojson.Safe.to_string
      (`Assoc [ "schemaType", `String "JSON"; "schema", `String schema ])
  in
  match
    Kafka_service_http.http_post
      ?ca_file
      net
      ~clock
      ~base_url:registry_url
      ~path:(Printf.sprintf "/subjects/%s" subject)
      ~content_type:"application/vnd.schemaregistry.v1+json"
      ~body
  with
  | Error e -> Error ("schema registry connect: " ^ e)
  | Ok (200, resp_body) ->
    decode_registration_response resp_body |> Result.map (fun r -> r.id)
  | Ok (404, _) ->
    Error
      (Printf.sprintf
         "subject '%s' has no registered schema matching the declared contract"
         subject)
  | Ok (status, resp_body) ->
    Error (Printf.sprintf "schema registry HTTP %d: %s" status resp_body)
;;

module Wire = struct
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
  ;;

  let decode bytes =
    if Bytes.length bytes < header_len
    then Error "wire format: message too short"
    else (
      let cs = Cstruct.of_bytes bytes in
      if Cstruct.get_char cs 0 <> magic_byte
      then Error "wire format: invalid magic byte"
      else (
        let schema_id = Int32.to_int (Cstruct.BE.get_uint32 cs 1) in
        let json_str = Cstruct.(to_string (sub cs header_len (length cs - header_len))) in
        Ok (schema_id, json_str)))
  ;;
end
