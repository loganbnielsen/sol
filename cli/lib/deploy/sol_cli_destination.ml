let resolve ~command ~local ~target =
  let open Result.Syntax in
  if local
  then Ok Sol_cli_kube_destination.local_context
  else (
    match target with
    | Some path ->
      let* cfg =
        Sol_cli_config.load_for_target ~target:path
        |> Result.map_error Sol_cli_config.error_to_string
      in
      Sol_cli_config.destination_of_target cfg.target
      |> Result.map Sol_cli_kube_destination.context_of_destination
    | None ->
      Error
        (Printf.sprintf
           "`sol %s` needs --target <env>/<provider>/<region> to know which cluster to \
            reach; for Sol's own local cluster use `sol local %s`"
           command
           command))
;;
