let insert_q =
  Caqti_request.Infix.(Caqti_type.(t4 string string int string) ->? Caqti_type.string)
    "INSERT INTO pluto_notifications (charge_id, customer_id, amount_cents, currency) \
     VALUES (?, ?, ?, ?) ON CONFLICT (charge_id) DO NOTHING RETURNING charge_id"
;;

let list_q =
  Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.(t4 string string int string))
    "SELECT charge_id, customer_id, amount_cents, currency FROM pluto_notifications \
     ORDER BY created_at DESC LIMIT 20"
;;

let insert pool ~charge_id ~customer_id ~amount_cents ~currency =
  Pg_db.find pool insert_q (charge_id, customer_id, amount_cents, currency)
;;

let list_recent pool = Pg_db.collect pool list_q ()
