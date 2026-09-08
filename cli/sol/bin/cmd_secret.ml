open Cmdliner

let workspace_name () = Filename.basename (Sys.getcwd ())

let namespace_or_exit ~workspace ~domain =
  match Sol_cli_deployment_plan.namespace_result ~workspace ~domain with
  | Ok namespace -> Sol_cli_deployment_plan.namespace_to_string namespace
  | Error err ->
    Printf.eprintf "error: %s\n" (Sol_cli_deployment_plan.plan_error_to_string err);
    exit 1

let discover_namespaces () =
  let workspace = workspace_name () in
  let app_dir = "app" in
  if not (Sys.file_exists app_dir && Sys.is_directory app_dir) then []
  else
    let domains = ref [] in
    (try
      Array.iter (fun entry ->
        let path = Filename.concat app_dir entry in
        if entry <> "" && entry.[0] <> '.' && Sys.is_directory path then
          domains := entry :: !domains
      ) (Sys.readdir app_dir)
    with _ -> ());
    List.rev_map (fun domain ->
      namespace_or_exit ~workspace ~domain
    ) !domains

let read_stdin () =
  String.trim (In_channel.input_all stdin)

let print_result = function
  | Ok result ->
    let out = Sol_cli_secret.redacted_result result in
    if out <> "" then Printf.printf "%s\n%!" out
  | Error msg ->
    Printf.eprintf "error: %s\n%!" msg;
    exit 1

let run_set env value key =
  let value = match value with
    | Some v -> v
    | None -> read_stdin ()
  in
  print_result
    (Sol_cli_secret.set
       ~env
       ~workspace:(workspace_name ())
       ~namespaces:(discover_namespaces ())
       ~key
       ~value)

let run_list env =
  print_result
    (Sol_cli_secret.list
       ~env
       ~workspace:(workspace_name ())
       ~namespaces:(discover_namespaces ()))

let run_delete env key =
  print_result
    (Sol_cli_secret.delete
       ~env
       ~workspace:(workspace_name ())
       ~namespaces:(discover_namespaces ())
       ~key)

let env_arg =
  Arg.(required & opt (some string) None &
       info ["env"] ~docv:"ENV"
         ~doc:"Target environment name. local/dev use the local Kubernetes path; hosted/sol_hosted use the hosted API boundary; other names use the customer-cloud Kubernetes path.")

let value_arg =
  Arg.(value & opt (some string) None &
       info ["value"] ~docv:"VALUE"
         ~doc:"Secret value. If omitted, the value is read from stdin.")

let key_arg =
  Arg.(required & pos 0 (some string) None &
       info [] ~docv:"KEY" ~doc:"Secret key, e.g. DATABASE_URL.")

let set_cmd =
  Cmd.v
    (Cmd.info "set" ~doc:"Create or update a secret key")
    Term.(const run_set $ env_arg $ value_arg $ key_arg)

let list_cmd =
  Cmd.v
    (Cmd.info "list" ~doc:"List secret keys without values")
    Term.(const run_list $ env_arg)

let delete_cmd =
  Cmd.v
    (Cmd.info "delete" ~doc:"Delete a secret key")
    Term.(const run_delete $ env_arg $ key_arg)

let cmd =
  Cmd.group
    (Cmd.info "secret" ~doc:"Manage environment-scoped secrets")
    [ set_cmd; list_cmd; delete_cmd ]
