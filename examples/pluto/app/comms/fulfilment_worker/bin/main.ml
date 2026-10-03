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
      ~service:"fulfilment-worker"
      ()
  in
  let pool = require_db_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) postgres_url in
  let kafka = Kafka_service.create kafka_config ~sw |> require_kafka "kafka create" in
  let fulfilled =
    Kafka_service.register kafka ~net:env#net ~clock:env#clock (module Order_fulfilled)
    |> require_kafka "kafka register"
  in
  let module W = Fulfilment_worker.Make (struct
      let pool = pool
      let ot = Sol_obs.obs_eio obs
    end)
  in
  let publish (publication : Sol_outbox.publication) =
    match Order_fulfilled.decode (Yojson.Safe.from_string publication.payload) with
    | Error msg -> Error msg
    | Ok event ->
      (match Order_fulfilled.key event with
       | Some key when key <> publication.key ->
         Error
           (Printf.sprintf
              "outbox key %s does not match the contract key %s"
              publication.key
              key)
       | _ ->
         Eio.Promise.await (Kafka_service.publish kafka fulfilled event)
         |> Result.map_error Kafka.Error.to_string)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (W.Fulfilled_outbox.relay ~env ~pool ~publish ~ot:obs ~metrics_port:0 ()
     |> Result.map_error Sol_outbox.run_error_to_string
     |> function
     | Ok () -> ()
     | Error msg -> failwith msg);
    `Stop_daemon);
  let retry_policy = { Sol_jobs.default_retry_policy with max_attempts = 20 } in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (W.Jobs.run ~env ~pool ~ot:obs ~metrics_port:0 ~retry_policy ()
     |> Result.map_error Sol_jobs.run_error_to_string
     |> function
     | Ok () -> ()
     | Error msg -> failwith msg);
    `Stop_daemon);
  let module WR = Worker.Make (W) in
  WR.run ~env ~config:kafka_config ~ot:obs ()
  |> Result.map_error Worker.run_error_to_string
  |> function
  | Ok () -> ()
  | Error msg -> failwith msg
;;
