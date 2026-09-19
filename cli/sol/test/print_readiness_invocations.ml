(* Prints every readiness check's kubectl argv so CI can validate each one
   against a real kubectl (INFRA-035).

   A readiness invocation is otherwise only reachable through [readiness], which
   needs a live cluster, so an argv kubectl does not accept cannot be caught until
   a real install fails. `kubectl rollout status deployment --all` shipped that
   way: it was never a valid invocation, so every platform reported [Unmet] and no
   target could reach Ready.

   Every provider is printed, not just the one a command happens to be addressed
   to: the storage assertion is provider-specific, so a provider whose argv is
   never validated is exactly the one that ships an invalid invocation.

   Output is one check per line, tab separated:

     <provider> <check name> \t <argv item> ...

   The checks take no other arguments, so one pass per provider covers all of
   them. *)

let () =
  Sol_cli_provider.all
  |> List.iter (fun provider ->
    Sol_cli_cloud_lifecycle.readiness_invocations ~provider
    |> List.iter (fun (name, argv) ->
      print_string (Sol_cli_provider.to_string provider ^ " " ^ name);
      List.iter
        (fun arg ->
           print_char '\t';
           print_string arg)
        argv;
      print_newline ()))
;;
