module Email_job = struct
  type t =
    { charge_id : string
    ; customer_id : string
    ; amount_cents : int
    ; currency : string
    }

  let kind (_ : t) = "send_receipt_email"
  let kinds = [ "send_receipt_email" ]

  let encode (t : t) =
    Printf.sprintf
      {|{"charge_id":%s,"customer_id":%s,"amount_cents":%d,"currency":%s}|}
      (Yojson.Safe.to_string (`String t.charge_id))
      (Yojson.Safe.to_string (`String t.customer_id))
      t.amount_cents
      (Yojson.Safe.to_string (`String t.currency))
  ;;

  let decode s =
    match Yojson.Safe.from_string s with
    | `Assoc fields ->
      (match
         ( List.assoc_opt "charge_id" fields
         , List.assoc_opt "customer_id" fields
         , List.assoc_opt "amount_cents" fields
         , List.assoc_opt "currency" fields )
       with
       | ( Some (`String charge_id)
         , Some (`String customer_id)
         , Some (`Int amount_cents)
         , Some (`String currency) ) ->
         Ok { charge_id; customer_id; amount_cents; currency }
       | _ -> Error ("invalid receipt-email job payload: " ^ s))
    | _ -> Error ("invalid receipt-email job payload: " ^ s)
  ;;

  let handle (t : t) =
    Printf.printf
      "[notify-worker] receipt email sent  charge=%-20s  customer=%-10s\n%!"
      t.charge_id
      t.customer_id;
    Ok ()
  ;;
end

module Jobs = Sol_jobs.Make (Email_job)

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
        let job =
          Email_job.
            { charge_id = msg.Message.charge_id
            ; customer_id = msg.Message.customer_id
            ; amount_cents = msg.Message.amount_cents
            ; currency = msg.Message.currency
            }
        in
        (match
           Pg_db.transaction pool (fun tx ->
             let open Result.Syntax in
             let* () = Notification.insert tx row in
             Jobs.enqueue tx ~dedupe_key:msg.Message.charge_id job)
         with
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
    | Error msg ->
      ignore msg;
      Worker.Fail
  ;;
end
