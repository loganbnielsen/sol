let resolve ~command ~local ~target =
  if local
  then Ok Sol_cli_kube_destination.local_context
  else (
    match target with
    | Some path ->
      (match Sol_cli_config.load_for_target ~target:path with
       | Error e -> Error (Sol_cli_config.error_to_string e)
       | Ok cfg ->
         let t = cfg.target in
         (match Sol_cli_config.destination_of_target t with
          | Error msg -> Error msg
          | Ok destination ->
            Ok (Sol_cli_kube_destination.context_of_destination destination)))
    | None ->
      Error
        (Printf.sprintf
           "`sol %s` needs --target <env>/<provider>/<region> to know which cluster to \
            reach; for Sol's own local cluster use `sol local %s`"
           command
           command))
;;
