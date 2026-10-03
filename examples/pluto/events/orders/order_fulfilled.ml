type t =
  { order_id : string
  ; item : string
  ; quantity : int
  ; correlation_id : string
  }

include Orders_contract.OrderFulfilled

let encode t =
  `Assoc
    [ "order_id", `String t.order_id
    ; "item", `String t.item
    ; "quantity", `Int t.quantity
    ; "correlation_id", `String t.correlation_id
    ]
;;

let required_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error (name ^ " must be a string")
  | None -> Error (name ^ " is required")
;;

let required_int fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some _ -> Error (name ^ " must be an integer")
  | None -> Error (name ^ " is required")
;;

open Result.Syntax

let decode = function
  | `Assoc fields ->
    let* order_id = required_string fields "order_id" in
    let* item = required_string fields "item" in
    let* quantity = required_int fields "quantity" in
    let* correlation_id = required_string fields "correlation_id" in
    Ok { order_id; item; quantity; correlation_id }
  | _ -> Error "expected object"
;;

let key t = Kafka_service.Contract.key_of_field key_field (encode t)
