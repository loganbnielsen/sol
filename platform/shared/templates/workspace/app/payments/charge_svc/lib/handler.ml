(* POST /charges  — publish Charged to Kafka
   GET  /health      — liveness probe
   GET  /notifications — list notifications written by notify_worker *)

(* FRIC-026: seed the RNG once. Without this the charge id is a fixed
   sequence per process start, so ids repeat across restarts. *)
let () = Random.self_init ()

let routes pool ~publish_charged ~obs = [
  Route.get "/health" ~auth:`Public (fun _req ->
    Response.ok "ok"
  );
  Route.post "/charges" ~auth:`Public (fun req ->
    let required_string json name =
      match Yojson.Basic.Util.member name json with
      | `String value -> Ok value
      | `Null         -> Error (name ^ " is required")
      | _             -> Error (name ^ " must be a string")
    in
    let required_int json name =
      match Yojson.Basic.Util.member name json with
      | `Int value -> Ok value
      | `Null      -> Error (name ^ " is required")
      | _          -> Error (name ^ " must be an integer")
    in
    let decode_charge json =
      Result.bind (required_string json "customer_id") @@ fun customer_id ->
      Result.bind (required_int json "amount_cents") @@ fun amount_cents ->
      Result.map
        (fun currency -> customer_id, amount_cents, currency)
        (required_string json "currency")
    in
    let parsed =
      try Ok (Yojson.Basic.from_string req.body)
      with Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
    in
    match Result.bind parsed decode_charge with
    | Error msg ->
      Response.bad_request msg
    | Ok (customer_id, amount_cents, currency) ->
      Sol_obs.with_span obs ?parent:req.trace_ctx "charges" (fun sp ->
        let charge_id = Printf.sprintf "ch_%06d" (Random.int 999999) in
        let event : Charged.t = {
          id             = charge_id;
          customer_id;
          amount_cents;
          currency;
          correlation_id = Option.value (Request.header req "x-correlation-id")
                             ~default:charge_id;
        } in
        Sol_obs.log sp Sol_obs.Info
          ~fields:[("charge_id", charge_id); ("customer_id", customer_id)]
          "charge accepted";
        match publish_charged event with
        | Ok () ->
          Response.json ~status:202
            (Printf.sprintf {|{"id":"%s","accepted":true}|} charge_id)
        | Error msg ->
          Response.internal_error ("publish failed: " ^ msg))
  );
  Route.get "/notifications" ~auth:`Public (fun _req ->
    match Notification.list_recent pool with
    | Error _  -> Response.json ~status:500 {|{"error":"db unavailable"}|}
    | Ok rows  ->
      let row_json (charge_id, customer_id, amount_cents, currency) =
        `Assoc [
          ("charge_id",    `String charge_id);
          ("customer_id",  `String customer_id);
          ("amount_cents", `Int amount_cents);
          ("currency",     `String currency);
        ]
      in
      Response.json (Yojson.Basic.to_string (`List (List.map row_json rows)))
  );
]
