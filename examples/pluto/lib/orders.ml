type order =
  { order_id : string
  ; item : string
  ; quantity : int
  ; status : string
  }

let insert_q =
  Caqti_request.Infix.(Caqti_type.(t3 string string int) ->? Caqti_type.string)
    "INSERT INTO orders (order_id, item, quantity) VALUES (?, ?, ?) ON CONFLICT \
     (order_id) DO NOTHING RETURNING status"
;;

let status_q =
  Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string)
    "SELECT status FROM orders WHERE order_id = ?"
;;

let read_q =
  Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.(t4 string string int string))
    "SELECT order_id, item, quantity, status FROM orders WHERE order_id = ?"
;;

let insert_fulfilled_q =
  Caqti_request.Infix.(Caqti_type.(t4 string string int string) ->? Caqti_type.string)
    "INSERT INTO fulfilled_orders (order_id, item, quantity, correlation_id) VALUES (?, \
     ?, ?, ?) ON CONFLICT (order_id) DO NOTHING RETURNING order_id"
;;

let mark_fulfilled_q =
  Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string)
    "UPDATE orders SET status = 'fulfilled', fulfilled_at = now() WHERE order_id = ? AND \
     fulfilled_at IS NULL RETURNING order_id"
;;

let progress_q =
  Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.(t2 bool bool))
    "SELECT fulfilled_at IS NOT NULL, confirmed_at IS NOT NULL FROM orders WHERE \
     order_id = ?"
;;

let insert_confirmation_q =
  Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string)
    "INSERT INTO order_confirmations (order_id) VALUES (?) ON CONFLICT (order_id) DO \
     NOTHING RETURNING order_id"
;;

let confirm_q =
  Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string)
    "UPDATE orders SET status = 'confirmed', confirmed_at = now() WHERE order_id = ? AND \
     fulfilled_at IS NOT NULL AND confirmed_at IS NULL RETURNING order_id"
;;

let insert tx ~order_id ~item ~quantity = Pg_db.find tx insert_q (order_id, item, quantity)
let status tx ~order_id = Pg_db.find tx status_q order_id

let read tx ~order_id =
  Pg_db.find tx read_q order_id
  |> Result.map
       (Option.map (fun (order_id, item, quantity, status) ->
          { order_id; item; quantity; status }))
;;

let insert_fulfilled tx ~order_id ~item ~quantity ~correlation_id =
  Pg_db.find tx insert_fulfilled_q (order_id, item, quantity, correlation_id)
  |> Result.map Option.is_some
;;

let mark_fulfilled tx ~order_id =
  Pg_db.find tx mark_fulfilled_q order_id |> Result.map (fun _ -> ())
;;

let progress tx ~order_id = Pg_db.find tx progress_q order_id

let confirm tx ~order_id =
  match progress tx ~order_id with
  | Error e -> Error e
  | Ok None -> Error (Pg_error.Query_error ("order " ^ order_id ^ " is missing"))
  | Ok (Some (_, true)) -> Ok ()
  | Ok (Some (false, _)) ->
    Error (Pg_error.Query_error ("order " ^ order_id ^ " is not fulfilled yet"))
  | Ok (Some (true, false)) ->
    let open Result.Syntax in
    let* _ = Pg_db.find tx insert_confirmation_q order_id in
    let* _ = Pg_db.find tx confirm_q order_id in
    Ok ()
;;
