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

let declared_workload_secrets ~facts ~workspace ~namespaces =
  Sol_cli_workspace_model.services facts
  |> List.filter_map (fun (s : Sol_cli_manifest.service) ->
    match
      ( Sol_cli_deployment_plan.namespace_name ~workspace ~domain:s.domain
      , Sol_cli_deployment_plan.k8s_name s.name )
    with
    | Ok ns, Ok name when List.mem ns namespaces ->
      Some (ns, Sol_cli_manifest.workload_secret_name name)
    | _ -> None)
;;

let print_result result =
  let* result = Sol_cli_exit.of_msg result in
  let out = Sol_cli_secret.redacted_result result in
  if out <> "" then Printf.printf "%s\n%!" out;
  Ok ()
;;

let load_facts () = Sol_cli_workspace_model.load_cwd () |> Sol_cli_exit.of_msg

let run_set ~ctx value key domain =
  let value =
    match value with
    | Some v -> v
    | None -> read_stdin ()
  in
  let* facts = load_facts () in
  let* namespaces = discover_namespaces ~facts ~domain in
  let workspace = workspace_name () in
  let declared = declared_workload_secrets ~facts ~workspace ~namespaces in
  Sol_cli_secret.set ~ctx ~workspace ~namespaces ~declared ~key ~value |> print_result
;;

let run_list ~ctx domain =
  let* facts = load_facts () in
  let* namespaces = discover_namespaces ~facts ~domain in
  Sol_cli_secret.list ~ctx ~workspace:(workspace_name ()) ~namespaces |> print_result
;;

let run_delete ~ctx key domain =
  let* facts = load_facts () in
  let* namespaces = discover_namespaces ~facts ~domain in
  Sol_cli_secret.delete ~ctx ~workspace:(workspace_name ()) ~namespaces ~key
  |> print_result
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

let context_term ~local ~command =
  if local
  then Term.const (Ok Cmd_destination.local)
  else Term.(const (Cmd_destination.remote ~command) $ Cmd_destination.target_arg)
;;

let set_cmd ~local =
  Cmd.v
    (Cmd.info "set" ~doc:"Create or update a secret key")
    Term.(
      const (fun ctx value key domain ->
        let result =
          let* ctx = ctx in
          run_set ~ctx value key domain
        in
        Sol_cli_exit.exit_on result)
      $ context_term ~local ~command:"secret set"
      $ value_arg
      $ key_arg
      $ domain_arg)
;;

let list_cmd ~local =
  Cmd.v
    (Cmd.info "list" ~doc:"List secret keys without values")
    Term.(
      const (fun ctx domain ->
        let result =
          let* ctx = ctx in
          run_list ~ctx domain
        in
        Sol_cli_exit.exit_on result)
      $ context_term ~local ~command:"secret list"
      $ domain_arg)
;;

let delete_cmd ~local =
  Cmd.v
    (Cmd.info "delete" ~doc:"Delete a secret key")
    Term.(
      const (fun ctx key domain ->
        let result =
          let* ctx = ctx in
          run_delete ~ctx key domain
        in
        Sol_cli_exit.exit_on result)
      $ context_term ~local ~command:"secret delete"
      $ key_arg
      $ domain_arg)
;;

let group ~local =
  Cmd.group
    (Cmd.info "secret" ~doc:"Manage secrets in a target cluster")
    [ set_cmd ~local; list_cmd ~local; delete_cmd ~local ]
;;

let cmd = group ~local:false
let local_cmd = group ~local:true
