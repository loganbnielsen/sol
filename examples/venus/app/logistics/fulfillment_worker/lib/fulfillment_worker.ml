module Message = Payment_confirmed

let group_id = "venus-logistics-fulfillment-worker"

let handle (msg : Message.t) ~trace_ctx:_ =
  Printf.printf "[fulfillment-worker] queuing shipment  payment=%s  charge=%s  customer=%s  %d %s\n%!"
    msg.Message.payment_id msg.Message.charge_id
    msg.Message.customer_id msg.Message.amount_cents msg.Message.currency;
  Ok ()
