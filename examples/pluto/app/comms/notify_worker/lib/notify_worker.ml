module Email_job = struct
  type t =
    { charge_id : string
    ; customer_id : string
    }

  let workspace = "pluto"
  let kind (_ : t) = "send_confirmation_email"
  let kinds = [ "send_confirmation_email" ]

  let encode (t : t) =
    Printf.sprintf
      {|{"charge_id":%s,"customer_id":%s}|}
      (Yojson.Safe.to_string (`String t.charge_id))
      (Yojson.Safe.to_string (`String t.customer_id))
  ;;

  let decode s =
    match Yojson.Safe.from_string s with
    | `Assoc fields ->
      (match List.assoc_opt "charge_id" fields, List.assoc_opt "customer_id" fields with
       | Some (`String charge_id), Some (`String customer_id) ->
         Ok { charge_id; customer_id }
       | _ -> Error ("invalid confirmation-email job payload: " ^ s))
    | _ -> Error ("invalid confirmation-email job payload: " ^ s)
  ;;

  let handle (t : t) =
    Printf.printf
      "[notify-worker] confirmation email sent  charge=%s  customer=%s\n%!"
      t.charge_id
      t.customer_id;
    Ok ()
  ;;
end

module Jobs = Sol_jobs.Make (Email_job)

module Notification_sent_outbox = Sol_outbox.Make (struct
    type t = Notification_sent.t

    let kind (_ : t) = "notification_sent"
    let kinds = [ "notification_sent" ]
    let encode (t : t) = Yojson.Safe.to_string (Notification_sent.encode t)
  end)

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
      Pg_db.transaction Config.pool (fun tx ->
        let open Result.Syntax in
        let* () =
          Notification.insert
            tx
            ~charge_id:msg.id
            ~customer_id:msg.customer_id
            ~amount_cents:msg.amount_cents
            ~currency:msg.currency
        in
        let* () =
          Jobs.enqueue
            tx
            ~dedupe_key:msg.id
            Email_job.{ charge_id = msg.id; customer_id = msg.customer_id }
        in
        Notification_sent_outbox.publish
          tx
          ~key:msg.id
          ~ord:1L
          Notification_sent.
            { charge_id = msg.id
            ; customer_id = msg.customer_id
            ; amount_cents = msg.amount_cents
            ; currency = msg.currency
            })
    with
    | Ok () -> Worker.Ack
    | Error e ->
      Obs_eio.log_standalone
        Config.ot
        Obs_eio.Error
        ~fields:[ "error", Pg_error.to_string e ]
        "db insert failed";
      Worker.Fail
  ;;
end
