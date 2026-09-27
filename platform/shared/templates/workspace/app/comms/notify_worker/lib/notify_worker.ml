module Make (Config : sig
  val pool : Pg_db.pool
  val obs  : Sol_obs.t
end) = struct

  module Message = Charged

  let group_id = "{{name}}-comms-notify-worker"

  let handle (msg : Message.t) ~trace_ctx:_ : Worker.outcome =
    Sol_obs.log_info Config.obs
      ~fields:[("charge_id", msg.id); ("customer_id", msg.customer_id);
               ("amount_cents", string_of_int msg.amount_cents)]
      "charge event received";
    match Notification.insert Config.pool
            ~charge_id:msg.id ~customer_id:msg.customer_id
            ~amount_cents:msg.amount_cents ~currency:msg.currency with
    | Ok ()   -> Worker.Ack
    | Error e ->
      Sol_obs.log_error Config.obs
        ~fields:[("error", Pg_error.to_string e)]
        "db insert failed";
      Worker.Retry (Pg_error.to_string e)

end
