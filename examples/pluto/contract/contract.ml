let events : (string * (module Kafka_service.MESSAGE)) list =
  [ "Charged", (module Charged)
  ; "Notification_sent", (module Notification_sent)
  ; "OrderPlaced", (module Order_placed)
  ; "OrderFulfilled", (module Order_fulfilled)
  ]
;;

let with_registry f =
  match Sys.getenv_opt "SCHEMA_REGISTRY_URL" with
  | None | Some "" -> failwith "SCHEMA_REGISTRY_URL is not set"
  | Some registry_url ->
    Eio_main.run @@ fun env -> f ~net:env#net ~clock:env#clock ~registry_url
;;

let check ~net ~clock ~registry_url =
  List.iter
    (fun (name, message) ->
       match Kafka_service.Schema.check ~net ~clock ~registry_url message with
       | Ok () -> Printf.printf "contract %s: compatible\n%!" name
       | Error e ->
         Printf.printf "contract %s: %s\n%!" name (Kafka_service.error_to_string e))
    events
;;

let apply ~net ~clock ~registry_url =
  let failed = ref false in
  List.iter
    (fun (name, message) ->
       match Kafka_service.Schema.register ~net ~clock ~registry_url message with
       | Ok id -> Printf.printf "contract %s: registered (schema id %d)\n%!" name id
       | Error e ->
         Printf.eprintf "contract %s: %s\n%!" name (Kafka_service.error_to_string e);
         failed := true)
    events;
  if !failed then exit 1
;;

let () =
  match Array.to_list Sys.argv with
  | _ :: "--json" :: _ ->
    print_endline (Yojson.Safe.to_string (Kafka_service.Contract.projection events))
  | _ :: "--check" :: _ -> with_registry check
  | _ :: "--apply" :: _ -> with_registry apply
  | _ ->
    prerr_endline "usage: contract [--json | --check | --apply]";
    exit 2
;;
