type t =
  { charge_id : string
  ; customer_id : string
  ; amount_cents : int
  ; currency : string
  }

include Comms_contract.Notification_sent

let encode t =
  `Assoc
    [ "charge_id", `String t.charge_id
    ; "customer_id", `String t.customer_id
    ; "amount_cents", `Int t.amount_cents
    ; "currency", `String t.currency
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
    let* charge_id = required_string fields "charge_id" in
    let* customer_id = required_string fields "customer_id" in
    let* amount_cents = required_int fields "amount_cents" in
    let* currency = required_string fields "currency" in
    Ok { charge_id; customer_id; amount_cents; currency }
  | _ -> Error "expected object"
;;

let key t = Kafka_service.Contract.key_of_field key_field (encode t)
