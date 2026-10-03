let env_nonempty name =
  match Sys.getenv_opt name with
  | Some value when value <> "" -> Some value
  | _ -> None
;;

let require_db_pool ~sw ~stdenv postgres_url =
  let url =
    match postgres_url with
    | Some url -> url
    | None -> failwith "db pool: POSTGRES_URL is required"
  in
  match Pg_db.create_pool ~url ~sw ~stdenv () with
  | Ok pool -> pool
  | Error e -> failwith ("db pool: " ^ Pg_error.to_string e)
;;

let require_kafka label = function
  | Ok value -> value
  | Error e -> failwith (label ^ ": " ^ Kafka_service.error_to_string e)
;;

module Placed_outbox = Sol_outbox.Make (struct
    type t = Order_placed.t

    let kind (_ : t) = "OrderPlaced"
    let kinds = [ "OrderPlaced" ]
    let encode (t : t) = Yojson.Safe.to_string (Order_placed.encode t)
  end)

let () =
  let postgres_url = env_nonempty "POSTGRES_URL" in
  let kafka_config = Kafka_service.config_of_env () |> require_kafka "kafka config" in
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let obs =
    Sol_obs.of_env
      ~sw
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"orders-svc"
      ()
  in
  let pool = require_db_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) postgres_url in
  let kafka = Kafka_service.create kafka_config ~sw |> require_kafka "kafka create" in
  let placed =
    Kafka_service.register kafka ~net:env#net ~clock:env#clock (module Order_placed)
    |> require_kafka "kafka register"
  in
  let module Jobs = Sol_jobs.Make (Orders_jobs.Make (struct
      let pool = pool
    end))
  in
  let publish (publication : Sol_outbox.publication) =
    match Order_placed.decode (Yojson.Safe.from_string publication.payload) with
    | Error msg -> Error msg
    | Ok event ->
      (match Order_placed.key event with
       | Some key when key <> publication.key ->
         Error
           (Printf.sprintf
              "outbox key %s does not match the contract key %s"
              publication.key
              key)
       | _ ->
         Eio.Promise.await (Kafka_service.publish kafka placed event)
         |> Result.map_error Kafka.Error.to_string)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (Placed_outbox.relay ~env ~pool ~publish ~ot:obs ~metrics_port:0 ()
     |> Result.map_error Sol_outbox.run_error_to_string
     |> function
     | Ok () -> ()
     | Error msg -> failwith msg);
    `Stop_daemon);
  let accept ~order_id ~item ~quantity ~correlation_id =
    Pg_db.transaction pool (fun tx ->
      let open Result.Syntax in
      match Orders.insert tx ~order_id ~item ~quantity with
      | Error e -> Error e
      | Ok None ->
        (match Orders.status tx ~order_id with
         | Ok (Some status) -> Ok status
         | Ok None ->
           Error
             (Pg_error.Query_error
                ("order " ^ order_id ^ " is missing after a duplicate insert"))
         | Error e -> Error e)
      | Ok (Some status) ->
        let event : Order_placed.t = { order_id; item; quantity; correlation_id } in
        let* () =
          Jobs.enqueue
            tx
            ~dedupe_key:order_id
            (Orders_jobs.Send_confirmation { order_id })
        in
        let* () = Placed_outbox.publish tx ~key:order_id ~ord:1L event in
        Ok status)
  in
  let deps : Orders_handler.deps =
    { accept; read = (fun ~order_id -> Orders.read pool ~order_id) }
  in
  Service.run (Orders_handler.routes ~obs:(Some obs) ~deps) ~env ~ot:obs ()
  |> Result.map_error Service.run_error_to_string
  |> function
  | Ok () -> ()
  | Error e -> failwith e
;;
