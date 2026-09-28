open Cmdliner

let workspace_name = Sol_cli_workspace.current_name

open Result.Syntax

let discover_namespaces ~facts ~domain =
  let workspace = workspace_name () in
  let domains =
    Sol_cli_workspace_model.services facts
    |> List.map (fun (s : Sol_cli_manifest.service) -> s.domain)
    |> List.sort_uniq compare
  in
  let* selected =
    match domain with
    | None -> Ok domains
    | Some requested ->
      (match List.filter (Sol_cli_deployment_scope.equal_name requested) domains with
       | [] ->
         let available_domains =
           match domains with
           | [] -> "(none)"
           | _ -> String.concat ", " domains
         in
         Error
           (Sol_cli_exit.error
              (Printf.sprintf
                 "--domain %S matches no workload; domains with units: %s"
                 requested
                 available_domains))
       | matched -> Ok matched)
  in
  selected
  |> Sol_cli_result.map_list (fun domain ->
    Sol_cli_deployment_plan.namespace_name ~workspace ~domain)
  |> Sol_cli_exit.of_msg
;;

let read_stdin () = String.trim (In_channel.input_all stdin)

let print_result result =
  let* result = Sol_cli_exit.of_msg result in
  let out = Sol_cli_secret.redacted_result result in
  if out <> "" then Printf.printf "%s\n%!" out;
  Ok ()
;;

let load_facts () = Sol_cli_workspace_model.load_cwd () |> Sol_cli_exit.of_msg

let run_set ~ctx env value key domain =
  let value =
    match value with
    | Some v -> v
    | None -> read_stdin ()
  in
  let* facts = load_facts () in
  let* namespaces = discover_namespaces ~facts ~domain in
  Sol_cli_secret.set ~ctx ~env ~workspace:(workspace_name ()) ~namespaces ~key ~value
  |> print_result
;;

let run_list ~ctx env domain =
  let* facts = load_facts () in
  let* namespaces = discover_namespaces ~facts ~domain in
  Sol_cli_secret.list ~ctx ~env ~workspace:(workspace_name ()) ~namespaces |> print_result
;;

let run_delete ~ctx env key domain =
  let* facts = load_facts () in
  let* namespaces = discover_namespaces ~facts ~domain in
  Sol_cli_secret.delete ~ctx ~env ~workspace:(workspace_name ()) ~namespaces ~key
  |> print_result
;;

let env_arg =
  Arg.(
    required
    & opt (some Sol_cli_args.text) None
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
    & pos 0 (some Sol_cli_args.text) None
    & info [] ~docv:"KEY" ~doc:"Secret key, e.g. DATABASE_URL.")
;;

let domain_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
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
    Term.(
      const (fun env value key domain target ->
        let result =
          let* ctx = Cmd_destination.remote ~command:"secret set" target in
          run_set ~ctx env value key domain
        in
        Sol_cli_exit.exit_on result)
      $ env_arg
      $ value_arg
      $ key_arg
      $ domain_arg
      $ Cmd_destination.target_arg)
;;

let list_cmd =
  Cmd.v
    (Cmd.info "list" ~doc:"List secret keys without values")
    Term.(
      const (fun env domain target ->
        let result =
          let* ctx = Cmd_destination.remote ~command:"secret list" target in
          run_list ~ctx env domain
        in
        Sol_cli_exit.exit_on result)
      $ env_arg
      $ domain_arg
      $ Cmd_destination.target_arg)
;;

let delete_cmd =
  Cmd.v
    (Cmd.info "delete" ~doc:"Delete a secret key")
    Term.(
      const (fun env key domain target ->
        let result =
          let* ctx = Cmd_destination.remote ~command:"secret delete" target in
          run_delete ~ctx env key domain
        in
        Sol_cli_exit.exit_on result)
      $ env_arg
      $ key_arg
      $ domain_arg
      $ Cmd_destination.target_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info "secret" ~doc:"Manage environment-scoped secrets")
    [ set_cmd; list_cmd; delete_cmd ]
;;
