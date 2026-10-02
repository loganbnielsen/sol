open Cmdliner

let resolve = Sol_cli_destination.resolve

let target_arg =
  Sol_cli_target_arg.flag
    ~doc:
      "Deployment target whose cluster this command operates on, e.g. \
       prod/aws/us-east-1. Required unless you use the `sol local <command>` form: Sol \
       never falls back to the ambient kubectl context."
;;

let remote ~command target = resolve ~command ~local:false ~target |> Sol_cli_exit.of_msg
let local = Sol_cli_kube_destination.local_context

let required_target_arg =
  Arg.(
    required
    & opt (some Sol_cli_args.text) None
    & info
        [ "target" ]
        ~docv:"ENV/PROVIDER/REGION"
        ~doc:
          "Deployment target whose cluster this command operates on, e.g. \
           prod/aws/us-east-1. Required: Sol never falls back to the ambient kubectl \
           context. For Sol's own local cluster use the `sol local <command>` form.")
;;
