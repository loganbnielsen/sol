let env_nonempty name =
  match Sys.getenv_opt name with
  | Some value when value <> "" -> Some value
  | _ -> None

let require_db_pool ~sw ~stdenv postgres_url =
  let url =
    match postgres_url with
    | Some url -> url
    | None -> failwith "db pool: POSTGRES_URL is required"
  in
  match Pg_db.create_pool ~url ~sw ~stdenv () with
  | Ok pool -> pool
  | Error e -> failwith ("db pool: " ^ Pg_error.to_string e)

let require_kafka label = function
  | Ok value -> value
  | Error e  -> failwith (label ^ ": " ^ Kafka_service.error_to_string e)

let () =
  let postgres_url = env_nonempty "POSTGRES_URL" in
  let kafka_config = Kafka_service.config_of_env () |> require_kafka "kafka config" in
  Eio_main.run @@ fun env ->
  let obs =
    Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"pluto-notify-worker" ~context:[("team", "comms")] ()
  in
  Eio.Switch.run @@ fun sw ->
  let pool = require_db_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) postgres_url in
  let module W = Notify_worker.Make(struct
    let pool = pool
    let ot   = Sol_obs.obs_eio obs
  end) in
  let module WR = Worker.Make(W) in
  WR.run ~env ~config:kafka_config ~ot:obs ()
  |> Result.map_error Worker.run_error_to_string
  |> function Ok () -> () | Error msg -> failwith msg
