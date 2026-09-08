(* Inject pool and observability handle via functor so there's no mutable state.
   Worker.Make requires module Message, group_id, and handle inside the functor. *)
module Make (Config : sig
  val pool : Pg_db.pool
  val ot   : Obs_eio.t
end) = struct

  module Message = Charged

  let group_id = "pluto-comms-notify-worker"

  let handle (msg : Message.t) ~trace_ctx:_ =
    Obs_eio.log_standalone Config.ot Obs_eio.Info
      ~fields:[("charge_id", msg.id); ("customer_id", msg.customer_id);
               ("amount_cents", string_of_int msg.amount_cents)]
      "charge event received";
    match Notification.insert Config.pool
            ~charge_id:msg.id ~customer_id:msg.customer_id
            ~amount_cents:msg.amount_cents ~currency:msg.currency with
    | Ok ()   -> Ok ()
    | Error e ->
      Obs_eio.log_standalone Config.ot Obs_eio.Error
        ~fields:[("error", Pg_error.to_string e)]
        "db insert failed";
      Error (Pg_error.to_string e)

end
