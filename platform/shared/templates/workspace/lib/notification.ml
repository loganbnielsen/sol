let insert_q =
  Caqti_request.Infix.(Caqti_type.(t4 string string int string) ->. Caqti_type.unit)
    "INSERT INTO {{name}}_notifications \
     (charge_id, customer_id, amount_cents, currency) \
     VALUES (?, ?, ?, ?)"

let list_q =
  Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.(t4 string string int string))
    "SELECT charge_id, customer_id, amount_cents, currency \
     FROM {{name}}_notifications \
     ORDER BY created_at DESC LIMIT 20"

let insert pool ~charge_id ~customer_id ~amount_cents ~currency =
  Pg_db.exec pool insert_q (charge_id, customer_id, amount_cents, currency)

let list_recent pool =
  Pg_db.collect pool list_q ()
