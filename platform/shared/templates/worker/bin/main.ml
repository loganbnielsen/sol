let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1

let require_kafka label = function
  | Ok value -> value
  | Error e  -> fatal (label ^ ": " ^ Kafka_service.error_to_string e)

let () = Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let config = Kafka_service.config_of_env () |> require_kafka "kafka config" in
  let obs =
    Sol_obs.of_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"{{name}}-worker" ()
  in
  let module W = Worker.Make({{Mod}}) in
  W.run ~env ~config ~ot:obs ()
  |> Result.map_error Worker.run_error_to_string
  |> function Ok () -> () | Error msg -> fatal msg
