open Cmdliner

(* REFAC-088: the resolution policy itself lives in the library
   ([Sol_cli_destination.resolve]) so the seam between the two entry points is
   testable without a cluster. This module is the Cmdliner-facing shell around
   it: the flag, the exit-on-error, and the local/named helpers the command
   modules use. *)

let resolve = Sol_cli_destination.resolve

let or_exit = function
  | Ok ctx -> ctx
  | Error msg ->
    Printf.eprintf "error: %s\n%!" msg;
    exit 1
;;

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
