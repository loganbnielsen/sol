open Cmdliner

(* REFAC-088: the resolution policy itself lives in the library
   ([Sol_cli_destination.resolve]) so the seam between the two entry points is
   testable without a cluster. This module is the Cmdliner-facing shell around
   it: the flag, and the local/named helpers the command modules use. *)

let resolve = Sol_cli_destination.resolve

(** The optional [--target] the top-level commands declare. It is deliberately
    *optional* in Cmdliner terms so the resolver -- not the parser -- produces
    the failure, because only the resolver can name `sol local <command>`. *)
let target_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "target" ]
        ~docv:"ENV/PROVIDER/REGION"
        ~doc:
          "Deployment target whose cluster this command operates on, e.g. \
           prod/aws/us-east-1. Required unless you use the `sol local <command>` form: \
           Sol never falls back to the ambient kubectl context.")
;;

(** The destination a top-level command's [--target] names, for the first step
    of its [let*] chain (REFAC-115). *)
let remote ~command target = resolve ~command ~local:false ~target |> Sol_cli_exit.of_msg

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
