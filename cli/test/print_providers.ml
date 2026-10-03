let status_string = function
  | Sol_cli_provider_capabilities.Root_present -> "present"
  | Sol_cli_provider_capabilities.Root_not_applicable -> "not_applicable"
  | Sol_cli_provider_capabilities.Root_not_implemented -> "not_implemented"
;;

let () =
  List.iter
    (fun provider ->
       Printf.printf
         "%s\t%s\n"
         (Sol_cli_provider.to_string provider)
         (status_string
            (Sol_cli_provider_capabilities.capabilities_of provider).root_status))
    Sol_cli_provider.all
;;
