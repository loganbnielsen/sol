type t =
  { id : string
  ; amount_cents : int
  ; customer_id : string
  ; currency : string
  ; correlation_id : string
  }

include Payments_contract.Charged

let encode t =
  `Assoc
    [ "id", `String t.id
    ; "amount_cents", `Int t.amount_cents
    ; "customer_id", `String t.customer_id
    ; "currency", `String t.currency
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
    let* id = required_string fields "id" in
    let* amount_cents = required_int fields "amount_cents" in
    let* customer_id = required_string fields "customer_id" in
    let* currency = required_string fields "currency" in
    let* correlation_id = required_string fields "correlation_id" in
    Ok { id; amount_cents; customer_id; currency; correlation_id }
  | _ -> Error "expected object"
;;

let key t = Kafka_service.Contract.key_of_field key_field (encode t)
