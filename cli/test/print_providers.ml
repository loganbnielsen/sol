(* Prints every provider Sol knows, one per line, for the shell guards that need the
   list (check_destroy_completeness.sh, check_provider_roots.sh). REFAC-100: the
   guards read it from here -- the exhaustive [Sol_cli_provider.all] -- instead of
   scraping [to_string]'s string literals out of the source. *)

let () =
  List.iter (fun p -> print_endline (Sol_cli_provider.to_string p)) Sol_cli_provider.all
;;
