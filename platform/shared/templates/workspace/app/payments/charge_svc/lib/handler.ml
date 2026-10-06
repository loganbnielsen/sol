let () = Random.self_init ()

type charge_input = {
  customer_id : string;
  amount_cents : int;
  currency : string;
}

type accepted_charge = { charge_id : string }

let required_string json name =
  match Yojson.Basic.Util.member name json with
  | `String value -> Ok value
  | `Null -> Error (name ^ " is required")
  | _ -> Error (name ^ " must be a string")

let required_int json name =
  match Yojson.Basic.Util.member name json with
  | `Int value -> Ok value
  | `Null -> Error (name ^ " is required")
  | _ -> Error (name ^ " must be an integer")

let decode_charge json =
  let open Result.Syntax in
  match json with
  | `Assoc _ ->
      let* customer_id = required_string json "customer_id" in
      let* amount_cents = required_int json "amount_cents" in
      let* currency = required_string json "currency" in
      Ok { customer_id; amount_cents; currency }
  | _ -> Error "request body must be a JSON object"

let decode_charge_body body =
  let parsed =
    try Ok (Yojson.Basic.from_string body)
    with Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
  in
  Result.bind parsed decode_charge

let create_charge ~publish_charged ~obs ~parent ~correlation_id input =
  Sol_obs.with_span obs ?parent "charges" (fun sp ->
      let charge_id = Printf.sprintf "ch_%06d" (Random.int 999999) in
      let event : Charged.t =
        {
          id = charge_id;
          customer_id = input.customer_id;
          amount_cents = input.amount_cents;
          currency = input.currency;
          correlation_id = Option.value correlation_id ~default:charge_id;
        }
      in
      Sol_obs.log sp Sol_obs.Info
        ~fields:[ ("charge_id", charge_id); ("customer_id", input.customer_id) ]
        "charge accepted";
      publish_charged event |> Result.map (fun () -> { charge_id }))

let charge_response = function
  | Ok { charge_id } ->
      Response.json ~status:202
        (Printf.sprintf {|{"id":"%s","accepted":true}|} charge_id)
  | Error msg -> Response.internal_error ("publish failed: " ^ msg)

let handle_charge ~publish_charged ~obs req =
  match decode_charge_body req.Request.body with
  | Error msg -> Response.bad_request msg
  | Ok input ->
      create_charge ~publish_charged ~obs ~parent:req.trace_ctx
        ~correlation_id:(Request.header req "x-correlation-id")
        input
      |> charge_response

let list_notifications pool _req =
  match Notification.list_recent pool with
  | Error _ -> Response.json ~status:500 {|{"error":"db unavailable"}|}
  | Ok rows ->
      let row_json (charge_id, customer_id, amount_cents, currency) =
        `Assoc
          [
            ("charge_id", `String charge_id);
            ("customer_id", `String customer_id);
            ("amount_cents", `Int amount_cents);
            ("currency", `String currency);
          ]
      in
      Response.json (Yojson.Basic.to_string (`List (List.map row_json rows)))

let routes pool ~publish_charged ~obs =
  [
    Route.external_ (Route.get "/health" (fun _req -> Response.ok "ok"));
    Route.external_ (Route.post "/charges" (handle_charge ~publish_charged ~obs));
    Route.external_ (Route.get "/notifications" (list_notifications pool));
  ]
