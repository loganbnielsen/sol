type t =
  { charge_id : string
  ; customer_id : string
  ; amount_cents : int
  ; currency : string
  }

let topic_name = Kafka_service.topic_name_exn "pluto-comms-notifications"

let schema =
  {|{
  "type": "object",
  "properties": {
    "charge_id":    { "type": "string"  },
    "customer_id":  { "type": "string"  },
    "amount_cents": { "type": "integer" },
    "currency":     { "type": "string"  }
  },
  "required": ["charge_id", "customer_id", "amount_cents", "currency"]
}|}
;;

let partitions = 3
let key t = Some t.charge_id

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
