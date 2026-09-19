(* Prints every readiness check's kubectl argv so CI can validate each one
   against a real kubectl (INFRA-035).

   A readiness invocation is otherwise only reachable through [readiness], which
   needs a live cluster, so an argv kubectl does not accept cannot be caught until
   a real install fails. `kubectl rollout status deployment --all` shipped that
   way: it was never a valid invocation, so every platform reported [Unmet] and no
   target could reach Ready.

   Output is one check per line, tab separated:

     <observability backend> \t <check name> \t <argv item> ...

   Every backend is printed because the checks differ per backend, and the
   cluster issuer is a placeholder: only the argv's shape is being validated. *)

let backends = [ "external"; "local"; "self_hosted_durable" ]

let () =
  List.iter
    (fun backend ->
       Sol_cli_cloud_lifecycle.readiness_invocations
         ~cluster_issuer:"letsencrypt-prod"
         ~observability_backend:backend
       |> List.iter (fun (name, argv) ->
         print_string backend;
         print_char '\t';
         print_string name;
         List.iter
           (fun arg ->
              print_char '\t';
              print_string arg)
           argv;
         print_newline ()))
    backends
;;
