open Cmdliner

let workspace_name () = Filename.basename (Sys.getcwd ())

let namespace_or_exit ~workspace ~domain =
  match Sol_cli_deployment_plan.namespace_result ~workspace ~domain with
  | Ok namespace -> Sol_cli_deployment_plan.namespace_to_string namespace
  | Error err ->
    Printf.eprintf "error: %s\n" (Sol_cli_deployment_plan.plan_error_to_string err);
    exit 1
;;

(* Namespaces are derived from discovered services (same mechanism sol
   up/sol deploy already use), not a raw listing of every app/ directory --
   a domain directory with no real, deployable (Dockerfile-having) service
   under it should never produce a namespace target, and an optional path
   filter lets a user scope to just the domain/service they mean to touch
   instead of every domain in the workspace (FRIC-013). *)
let discover_namespaces ~filter_path =
  let workspace = workspace_name () in
  Sol_cli_manifest.discover_services ~filter_path
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

let run_set env value key filter_path =
  let value =
    match value with
    | Some v -> v
    | None -> read_stdin ()
  in
  print_result
    (Sol_cli_secret.set
       ~env
       ~workspace:(workspace_name ())
       ~namespaces:(discover_namespaces ~filter_path)
       ~key
       ~value)
;;

let run_list env filter_path =
  print_result
    (Sol_cli_secret.list
       ~env
       ~workspace:(workspace_name ())
       ~namespaces:(discover_namespaces ~filter_path))
;;

let run_delete env key filter_path =
  print_result
    (Sol_cli_secret.delete
       ~env
       ~workspace:(workspace_name ())
       ~namespaces:(discover_namespaces ~filter_path)
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

let path_arg_after_key =
  Arg.(
    value
    & pos 1 (some string) None
    & info
        []
        ~docv:"PATH"
        ~doc:
          "Domain/service path to scope this secret to (default: every domain discovered \
           in the workspace). Matches the same discover_services filter sol up/sol \
           deploy use, e.g. 'payments' or 'payments/charge-svc'.")
;;

let path_arg =
  Arg.(
    value
    & pos 0 (some string) None
    & info
        []
        ~docv:"PATH"
        ~doc:
          "Domain/service path to scope this secret to (default: every domain discovered \
           in the workspace). Matches the same discover_services filter sol up/sol \
           deploy use, e.g. 'payments' or 'payments/charge-svc'.")
;;

let set_cmd =
  Cmd.v
    (Cmd.info "set" ~doc:"Create or update a secret key")
    Term.(const run_set $ env_arg $ value_arg $ key_arg $ path_arg_after_key)
;;

let list_cmd =
  Cmd.v
    (Cmd.info "list" ~doc:"List secret keys without values")
    Term.(const run_list $ env_arg $ path_arg)
;;

let delete_cmd =
  Cmd.v
    (Cmd.info "delete" ~doc:"Delete a secret key")
    Term.(const run_delete $ env_arg $ key_arg $ path_arg_after_key)
;;

let cmd =
  Cmd.group
    (Cmd.info "secret" ~doc:"Manage environment-scoped secrets")
    [ set_cmd; list_cmd; delete_cmd ]
;;
