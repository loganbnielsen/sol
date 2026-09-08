(** Notification storage — owned by the comms team.
    Records a charge notification in the database once per Charged event. *)

module Schema = struct
  let table     = "notifications"
  let id_column = "charge_id"
  let columns   = ["charge_id"; "amount_cents"; "customer_id"; "currency"]

  type t = {
    charge_id    : string;
    amount_cents : int;
    customer_id  : string;
    currency     : string;
  }

  type id = string

  let row_type =
    Caqti_type.(custom
      ~encode:(fun r -> Ok (r.charge_id, r.amount_cents, r.customer_id, r.currency))
      ~decode:(fun (charge_id, amount_cents, customer_id, currency) ->
        Ok { charge_id; amount_cents; customer_id; currency })
      (t4 string int string string))

  let id_type = Caqti_type.string
  let get_id (r : t) = r.charge_id
end

type t = Schema.t

include Pg_table.Make(Schema)
