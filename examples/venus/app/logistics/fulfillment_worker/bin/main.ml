let () = Eio_main.run @@ fun env ->
  let config =
    match Kafka_service.config_of_env () with
    | Ok config -> config
    | Error e   -> failwith ("kafka config: " ^ Kafka_service.error_to_string e)
  in
  let obs =
    Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"venus-logistics-fulfillment-worker" ()
  in
  let module W = Worker.Make(Fulfillment_worker) in
  W.run ~env ~config ~ot:obs ()
  |> Result.map_error Worker.run_error_to_string
  |> function Ok () -> () | Error msg -> failwith msg
