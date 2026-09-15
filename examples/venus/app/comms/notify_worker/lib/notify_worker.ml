(** comms / notify-worker — Worker.RETRYABLE_WORKER implementation (it can
    return Worker.Retry on a DB failure, so it isn't Ack-only). Consumes
    Charged events, logs them via Obs, and records a notification in
    PostgreSQL. The pool and observability handle are injected via functor
    so the module itself has no mutable state. Run via Worker.Make_with_retry
    with an explicit ~retry_strategy (FEAT-078: no implicit fallback). *)

module Make (Config : sig
    val pool : Pg_db.pool option
    val ot : Obs_eio.t
  end) =
struct
  module Message = Charged

  let group_id = "comms-notify-worker"

  let handle (msg : Message.t) ~trace_ctx : Worker.outcome =
    Obs_eio.with_span Config.ot ?parent:trace_ctx "record_notification" (fun span ->
      Obs_eio.log
        span
        Info
        ~fields:
          [ "charge_id", msg.Message.charge_id
          ; "customer_id", msg.Message.customer_id
          ; "amount_cents", string_of_int msg.Message.amount_cents
          ; "currency", msg.Message.currency
          ]
        "recording charge notification");
    let persist_result =
      match Config.pool with
      | None -> Ok ()
      | Some pool ->
        let row =
          Notification.Schema.
            { charge_id = msg.Message.charge_id
            ; amount_cents = msg.Message.amount_cents
            ; customer_id = msg.Message.customer_id
            ; currency = msg.Message.currency
            }
        in
        (match Notification.insert pool row with
         | Ok () -> Ok ()
         | Error e ->
           let msg = Pg_error.to_string e in
           Printf.eprintf "[notify-worker] db error: %s\n%!" msg;
           Error msg)
    in
    match persist_result with
    | Ok () ->
      Printf.printf
        "[notify-worker] recorded   charge=%-20s  customer=%-10s  %5d %s\n%!"
        msg.Message.charge_id
        msg.Message.customer_id
        msg.Message.amount_cents
        msg.Message.currency;
      Worker.Ack
    | Error msg -> Worker.Retry msg
  ;;
end
