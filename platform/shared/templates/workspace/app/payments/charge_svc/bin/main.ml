let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1

let require_kafka label = function
  | Ok value -> value
  | Error e  -> fatal (label ^ ": " ^ Kafka_service.error_to_string e)

let require_db_pool ~sw ~stdenv =
  match Pg_db.of_env ~sw ~stdenv () with
  | Ok pool -> pool
  | Error e -> fatal ("db pool: " ^ Pg_error.to_string e)

let () =
  let kafka_config = Kafka_service.config_of_env () |> require_kafka "kafka config" in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let obs =
    Sol_obs.of_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"{{name}}-charge-svc" ~context:[("team", "payments")] ()
  in
  let pool = require_db_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) in
  let kafka = Kafka_service.create kafka_config ~sw |> require_kafka "kafka create" in
  let charged_topic =
    Kafka_service.register kafka ~net:env#net ~clock:env#clock (module Charged)
    |> require_kafka "kafka register"
  in
  let publish_charged event =
    match Eio.Promise.await (Kafka_service.publish kafka charged_topic event) with
    | Ok () -> Ok ()
    | Error e -> Error (Kafka.Error.to_string e)
  in
  Service.run (Handler.routes pool ~publish_charged ~obs) ~env
    ~ot:obs ()
  |> Result.map_error Service.run_error_to_string
  |> function Ok () -> () | Error e -> fatal e
