type t = {
  id      : string;
  payload : string;
}

include {{Team}}_contract.{{Mod}}

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

let key t = Kafka_service.Contract.key_of_field key_field (encode t)
