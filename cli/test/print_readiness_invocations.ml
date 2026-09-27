let () =
  Sol_cli_provider.all
  |> List.iter (fun provider ->
    Sol_cli_cloud_lifecycle.readiness_invocations ~provider
    |> List.iter (fun (name, argv) ->
      print_string (Sol_cli_provider.to_string provider ^ " " ^ name);
      argv
      |> List.iter (fun arg ->
        print_char '\t';
        print_string arg);
      print_newline ()))
;;
