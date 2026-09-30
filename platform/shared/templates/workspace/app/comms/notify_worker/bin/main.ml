let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1

let require_db_pool ~sw ~stdenv =
  match Pg_db.of_env ~sw ~stdenv () with
  | Ok pool -> pool
  | Error e -> fatal ("db pool: " ^ Pg_error.to_string e)

let require_kafka label = function
  | Ok value -> value
  | Error e -> fatal (label ^ ": " ^ Kafka_service.error_to_string e)

let () =
  let kafka_config =
    Kafka_service.config_of_env () |> require_kafka "kafka config"
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let obs =
    Sol_obs.of_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"{{name}}-notify-worker"
      ~context:[ ("team", "comms") ]
      ()
  in
  let pool = require_db_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) in
  let module W = Notify_worker.Make (struct
    let pool = pool
    let obs = obs
  end) in
  let module WR = Worker.Make (W) in
  WR.run ~env ~config:kafka_config ~ot:obs ()
  |> Result.map_error Worker.run_error_to_string
  |> function
  | Ok () -> ()
  | Error msg -> fatal msg
