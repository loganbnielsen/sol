module Make (Config : sig
    val pool : Pg_db.pool
    val ot : Obs_eio.t
  end) =
struct
  module Message = Order_placed

  let group_id = "pluto-orders-fulfilment-worker"

  module Fulfilled_outbox = Sol_outbox.Make (struct
      type t = Order_fulfilled.t

      let kind (_ : t) = "OrderFulfilled"
      let kinds = [ "OrderFulfilled" ]
      let encode (t : t) = Yojson.Safe.to_string (Order_fulfilled.encode t)
    end)

  module Jobs = Sol_jobs.Make (Orders_jobs.Make (struct
      let pool = Config.pool
    end))

  let handle (msg : Message.t) ~trace_ctx:_ : Worker.outcome =
    Obs_eio.log_standalone
      Config.ot
      Obs_eio.Info
      ~fields:
        [ "order_id", msg.order_id
        ; "item", msg.item
        ; "quantity", string_of_int msg.quantity
        ]
      "order placed received";
    match
      Pg_db.transaction Config.pool (fun tx ->
        let open Result.Syntax in
        let* inserted =
          Orders.insert_fulfilled
            tx
            ~order_id:msg.order_id
            ~item:msg.item
            ~quantity:msg.quantity
            ~correlation_id:msg.correlation_id
        in
        match inserted with
        | false -> Ok ()
        | true ->
          let* () =
            Jobs.enqueue
              tx
              ~dedupe_key:msg.order_id
              (Orders_jobs.Release_inventory { order_id = msg.order_id })
          in
          let event : Order_fulfilled.t =
            { order_id = msg.order_id
            ; item = msg.item
            ; quantity = msg.quantity
            ; correlation_id = msg.correlation_id
            }
          in
          Fulfilled_outbox.publish tx ~key:msg.order_id ~ord:1L event)
    with
    | Ok () -> Worker.Ack
    | Error e ->
      Obs_eio.log_standalone
        Config.ot
        Obs_eio.Error
        ~fields:[ "order_id", msg.order_id; "error", Pg_error.to_string e ]
        "order fulfilment failed";
      Worker.Fail
  ;;
end
