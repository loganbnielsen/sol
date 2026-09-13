open Cmdliner

(* FEAT-063: one place resolves a command's Kubernetes destination from the CLI.

   Either the command is the local form (`sol local <command>`), in which case
   the destination is the literal local cluster Sol owns, or it is the top-level
   form and must name a target, whose configuration supplies the destination.
   There is deliberately no third case: falling back to "whatever kubectl is
   pointed at" is the hidden input DEC-020 removes, so a top-level command with
   no `--target` fails closed and names the local spelling. *)

let resolve ~command ~local ~target =
  if local
  then Ok Sol_cli_kube_destination.local_context
  else (
    match target with
    | Some path ->
      (match Sol_cli_config.load_for_target ~target:path with
       | Error e -> Error (Sol_cli_config.error_to_string e)
       | Ok cfg ->
         (match cfg.Sol_cli_config.target with
          | None ->
            Error
              (Printf.sprintf
                 "target %s declares no kube_context, so Sol cannot tell which cluster to \
                  reach; add `kube_context:` to its target file"
                 path)
          | Some t ->
            (match Sol_cli_config.destination_of_target t with
             | Error msg -> Error msg
             | Ok destination ->
               Ok (Sol_cli_kube_destination.context_of_destination destination))))
    | None ->
      Error
        (Printf.sprintf
           "`sol %s` needs --target <env>/<provider>/<region> to know which cluster to \
            reach; for Sol's own local cluster use `sol local %s`"
           command
           command))
;;

let or_exit = function
  | Ok ctx -> ctx
  | Error msg ->
    Printf.eprintf "error: %s\n%!" msg;
    exit 1
;;

(** Resolve the destination for a top-level command's term. *)
let top ~command target = or_exit (resolve ~command ~local:false ~target:(Some target))

(** The local form's destination: Sol's own cluster, named literally. *)
let local = Sol_cli_kube_destination.local_context

let required_target_arg =
  Arg.(
    required
    & opt (some string) None
    & info
        [ "target" ]
        ~docv:"ENV/PROVIDER/REGION"
        ~doc:
          "Deployment target whose cluster this command operates on, e.g. \
           prod/aws/us-east-1. Required: Sol never falls back to the ambient kubectl \
           context. For Sol's own local cluster use the `sol local <command>` form.")
;;
