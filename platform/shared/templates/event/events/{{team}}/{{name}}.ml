type t = {
  id      : string;
  payload : string;
}

let topic_name = Kafka_service.topic_name_exn "{{team}}-{{name}}s"

let schema = {|{
  "type": "object",
  "properties": {
    "id":      { "type": "string" },
    "payload": { "type": "string" }
  },
  "required": ["id", "payload"]
}|}

let encode t = `Assoc [
  ("id",      `String t.id);
  ("payload", `String t.payload);
]

let required_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _              -> Error (name ^ " must be a string")
  | None                -> Error (name ^ " is required")

open Result.Syntax

let decode = function
  | `Assoc fields ->
    let* id = required_string fields "id" in
    let* payload = required_string fields "payload" in
    Ok { id; payload }
  | _ -> Error "expected object"
