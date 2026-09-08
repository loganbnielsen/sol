(* POST /charges  — write notification to DB
   GET  /health      — liveness probe
   GET  /notifications — list recent charges from DB *)

let routes pool = [
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
      let charge_id = Printf.sprintf "ch_%06d" (Random.int 999999) in
      (match Notification.insert pool
               ~charge_id ~customer_id ~amount_cents ~currency with
       | Ok () ->
         Response.json ~status:202
           (Printf.sprintf {|{"id":"%s","accepted":true}|} charge_id)
       | Error e ->
         Response.internal_error ("db insert failed: " ^ Pg_error.to_string e))
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
