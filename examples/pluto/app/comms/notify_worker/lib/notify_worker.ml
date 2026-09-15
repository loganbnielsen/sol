(* Inject pool and observability handle via functor so there's no mutable state.
   Worker.Make_with_retry requires module Message, group_id, and handle inside
   the functor. This worker can return Worker.Retry on a DB failure, so it
   satisfies Worker.RETRYABLE_WORKER (not the Ack-only Worker.WORKER) and must
   be run via Worker.Make_with_retry with an explicit ~retry_strategy
   (FEAT-078: no implicit fallback). *)
module Make (Config : sig
    val pool : Pg_db.pool
    val ot : Obs_eio.t
  end) =
struct
  module Message = Charged

  let group_id = "pluto-comms-notify-worker"

  let handle (msg : Message.t) ~trace_ctx:_ : Worker.outcome =
    Obs_eio.log_standalone
      Config.ot
      Obs_eio.Info
      ~fields:
        [ "charge_id", msg.id
        ; "customer_id", msg.customer_id
        ; "amount_cents", string_of_int msg.amount_cents
        ]
      "charge event received";
    match
      Notification.insert
        Config.pool
        ~charge_id:msg.id
        ~customer_id:msg.customer_id
        ~amount_cents:msg.amount_cents
        ~currency:msg.currency
    with
    | Ok () -> Worker.Ack
    | Error e ->
      Obs_eio.log_standalone
        Config.ot
        Obs_eio.Error
        ~fields:[ "error", Pg_error.to_string e ]
        "db insert failed";
      Worker.Retry (Pg_error.to_string e)
  ;;
end
