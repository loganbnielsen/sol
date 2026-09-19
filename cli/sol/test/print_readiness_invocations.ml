(* Prints every readiness check's kubectl argv so CI can validate each one
   against a real kubectl (INFRA-035).

   A readiness invocation is otherwise only reachable through [readiness], which
   needs a live cluster, so an argv kubectl does not accept cannot be caught until
   a real install fails. `kubectl rollout status deployment --all` shipped that
   way: it was never a valid invocation, so every platform reported [Unmet] and no
   target could reach Ready.

   Output is one check per line, tab separated:

     <check name> \t <argv item> ...

   The checks take no arguments, so one pass covers all of them. *)

let () =
  Sol_cli_cloud_lifecycle.readiness_invocations ()
  |> List.iter (fun (name, argv) ->
    print_string name;
    List.iter
      (fun arg ->
         print_char '\t';
         print_string arg)
      argv;
    print_newline ())
;;
