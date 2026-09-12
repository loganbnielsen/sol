open Cmdliner

let workspace_name () = Filename.basename (Sys.getcwd ())

let namespace_or_exit ~workspace ~domain =
  match Sol_cli_deployment_plan.namespace_result ~workspace ~domain with
  | Ok namespace -> Sol_cli_deployment_plan.namespace_to_string namespace
  | Error err ->
    Printf.eprintf "error: %s\n" (Sol_cli_deployment_plan.plan_error_to_string err);
    exit 1
;;

(* Secrets are addressed by Kubernetes namespace, not by workload, so this
   command deliberately does not accept [--scope]: a secret operation does not
   consume a *deployment* scope, and shipping [--scope payments/charge_svc] here
   would imply a unit granularity that the underlying object cannot honour
   (FEAT-065's invariant). [--domain] is the honest vocabulary.

   Namespaces are still derived from discovery (the same mechanism sol up/sol
   deploy use), because a domain directory with no deployable service should
   never produce a namespace target -- but the command owns that derivation.
   A [--domain] that matches no workload fails closed and names the domains that
   exist, rather than silently touching no namespace. *)
let discover_namespaces ~domain =
  let workspace = workspace_name () in
  let services = Sol_cli_manifest.discover_services () in
  let domains =
    services
    |> List.map (fun (s : Sol_cli_manifest.service) -> s.Sol_cli_manifest.domain)
    |> List.sort_uniq compare
  in
  (match domain with
   | None -> ()
   | Some requested ->
     if not (List.exists (Sol_cli_deployment_scope.equal_name requested) domains)
     then (
       Printf.eprintf
         "error: --domain %S matches no workload; domains with units: %s\n"
         requested
         (match domains with
          | [] -> "(none)"
          | _ -> String.concat ", " domains);
       exit 1));
  services
  |> List.filter (fun (s : Sol_cli_manifest.service) ->
    match domain with
    | None -> true
    | Some requested -> Sol_cli_deployment_scope.equal_name requested s.domain)
  |> List.map (fun (s : Sol_cli_manifest.service) -> s.Sol_cli_manifest.domain)
  |> List.sort_uniq compare
  |> List.map (fun domain -> namespace_or_exit ~workspace ~domain)
;;

let read_stdin () = String.trim (In_channel.input_all stdin)

let print_result = function
  | Ok result ->
    let out = Sol_cli_secret.redacted_result result in
    if out <> "" then Printf.printf "%s\n%!" out
  | Error msg ->
    Printf.eprintf "error: %s\n%!" msg;
    exit 1
;;

let run_set env value key domain =
  let value =
    match value with
    | Some v -> v
    | None -> read_stdin ()
  in
  print_result
    (Sol_cli_secret.set
       ~env
       ~workspace:(workspace_name ())
       ~namespaces:(discover_namespaces ~domain)
       ~key
       ~value)
;;

let run_list env domain =
  print_result
    (Sol_cli_secret.list
       ~env
       ~workspace:(workspace_name ())
       ~namespaces:(discover_namespaces ~domain))
;;

let run_delete env key domain =
  print_result
    (Sol_cli_secret.delete
       ~env
       ~workspace:(workspace_name ())
       ~namespaces:(discover_namespaces ~domain)
       ~key)
;;

let env_arg =
  Arg.(
    required
    & opt (some string) None
    & info
        [ "env" ]
        ~docv:"ENV"
        ~doc:
          "Target environment name. local/dev use the local Kubernetes path; \
           hosted/sol_hosted use the hosted API boundary; other names use the \
           customer-cloud Kubernetes path.")
;;

let value_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "value" ]
        ~docv:"VALUE"
        ~doc:"Secret value. If omitted, the value is read from stdin.")
;;

let key_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"KEY" ~doc:"Secret key, e.g. DATABASE_URL.")
;;

let domain_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "domain" ]
        ~docv:"DOMAIN"
        ~doc:
          "Restrict the operation to one domain's namespace (`payments`). Omit for every \
           domain discovered in the workspace. Domains are derived from deployable \
           services, so a directory with no workload is never targeted.")
;;

let set_cmd =
  Cmd.v
    (Cmd.info "set" ~doc:"Create or update a secret key")
    Term.(const run_set $ env_arg $ value_arg $ key_arg $ domain_arg)
;;

let list_cmd =
  Cmd.v
    (Cmd.info "list" ~doc:"List secret keys without values")
    Term.(const run_list $ env_arg $ domain_arg)
;;

let delete_cmd =
  Cmd.v
    (Cmd.info "delete" ~doc:"Delete a secret key")
    Term.(const run_delete $ env_arg $ key_arg $ domain_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info "secret" ~doc:"Manage environment-scoped secrets")
    [ set_cmd; list_cmd; delete_cmd ]
;;
