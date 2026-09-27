module Message = struct
  type t = { id : string }
  let topic_name = Kafka_service.topic_name_exn "{{domain}}-{{name}}-events"
  let schema = {|{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}|}
  let encode t = `Assoc [("id", `String t.id)]
  let required_string fields name =
    match List.assoc_opt name fields with
    | Some (`String value) -> Ok value
    | Some _              -> Error (name ^ " must be a string")
    | None                -> Error (name ^ " is required")
  open Result.Syntax
  let decode = function
    | `Assoc fields ->
      let* id = required_string fields "id" in
      Ok { id }
    | _ -> Error "expected object"
end

let group_id = "{{domain}}-{{name}}-worker"

let handle (msg : Message.t) ~trace_ctx:_ =
  Printf.printf "[{{name}}-worker] received id=%s\n%!" msg.id;
  Worker.Ack
