(** Event contracts for the Sol demo. In a real Sol workspace these would live
    in events/<team>/<name>.ml, owned by the team that publishes them and
    imported by consuming workers. *)

module OrderPlaced = struct
  type t = {
    order_id : string;
    item : string;
    quantity : int;
    correlation_id : string;
        (* propagated from the HTTP X-Correlation-Id header *)
  }

  let topic_name = Kafka_service.topic_name_exn "sol-demo-orders"

  let schema =
    {|{
    "type": "object",
    "properties": {
      "order_id":       { "type": "string"  },
      "item":           { "type": "string"  },
      "quantity":       { "type": "integer" },
      "correlation_id": { "type": "string"  }
    },
    "required": ["order_id", "item", "quantity", "correlation_id"]
  }|}

  let encode t =
    `Assoc
      [
        ("order_id", `String t.order_id);
        ("item", `String t.item);
        ("quantity", `Int t.quantity);
        ("correlation_id", `String t.correlation_id);
      ]

  let ( let* ) = Result.bind

  let required_string fields name =
    match List.assoc_opt name fields with
    | Some (`String value) -> Ok value
    | Some _ -> Error (name ^ " must be a string")
    | None -> Error (name ^ " is required")

  let required_int fields name =
    match List.assoc_opt name fields with
    | Some (`Int value) -> Ok value
    | Some _ -> Error (name ^ " must be an integer")
    | None -> Error (name ^ " is required")

  let decode = function
    | `Assoc fields ->
        let* order_id = required_string fields "order_id" in
        let* item = required_string fields "item" in
        let* quantity = required_int fields "quantity" in
        let* correlation_id = required_string fields "correlation_id" in
        Ok { order_id; item; quantity; correlation_id }
    | _ -> Error "expected object"
end
