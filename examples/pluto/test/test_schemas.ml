let () =
  match Sys.getenv_opt "SCHEMA_REGISTRY_URL" with
  | None -> Printf.printf "SCHEMA_REGISTRY_URL not set — skipping schema compat check\n%!"
  | Some registry_url ->
    Eio_main.run (fun env ->
      match
        Kafka_service.Schema.check_all
          ~net:env#net
          ~clock:env#clock
          ~registry_url
          [ (module Charged); (module Notification_sent) ]
      with
      | Ok () -> Printf.printf "schema compatibility: ok\n%!"
      | Error e ->
        Printf.eprintf
          "schema compatibility FAILED: %s\n%!"
          (Kafka_service.error_to_string e);
        exit 1)
;;
