let () =
  List.iter (fun p -> print_endline (Sol_cli_provider.to_string p)) Sol_cli_provider.all
;;
