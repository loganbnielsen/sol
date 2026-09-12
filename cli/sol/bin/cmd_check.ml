open Cmdliner

(* A requested scope must resolve, or the command fails. That rule is the point
   of the vocabulary (FEAT-061): a name that matches nothing is an error naming
   what exists, never a quiet empty selection that reports success. *)
let fail message =
  Printf.eprintf "sol check: %s\n" message;
  exit 2
;;

(* [scope] names what to check. There is no positional selector (FEAT-064):
   a name and a directory are different concepts, and one argument meaning
   "maybe one, maybe the other" is exactly what made selection unpredictable.
   Resolving a scope needs discovery, because the kind of a unit comes from what
   is on disk rather than from what the user typed -- and it goes through the
   same [Sol_cli_workload_selection] every other command uses (FEAT-065). *)
let run scope =
  let findings =
    match scope with
    | None -> Sol_cli_check.run ()
    | Some requested ->
      let services =
        match Sol_cli_manifest.discover_services_result () with
        | Ok services -> services
        | Error _ ->
          fail "--scope needs a workspace to resolve against (no app/ directory here)"
      in
      let selected =
        match
          Sol_cli_workload_selection.resolve ~what:"--scope" (Some requested) services
        with
        | Ok selected -> selected
        | Error message -> fail message
      in
      (* Reading is allowed to find nothing: an empty workspace is an answer, not
         a failure. The mutating commands decide the opposite, which is why
         emptiness is reported by the resolver rather than judged by it. *)
      Sol_cli_check.run_services selected.Sol_cli_workload_selection.services
  in
  List.iter (fun f -> Printf.eprintf "%s\n" (Sol_cli_check.finding_to_string f)) findings;
  if Sol_cli_check.has_errors findings then exit 1 else Printf.printf "sol check: ok\n"
;;

(** Workload selection. The command has exactly one grammar: the positional PATH
    it used to accept is deleted, so a stray argument fails through the parser
    rather than quietly meaning something else. There is deliberately no
    rejected-argument shim — a shim would put an `[ARG]` in this usage line
    permanently, adding invalid grammar to the surface to produce a nicer error
    for it. *)
let scope_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "scope" ]
        ~docv:"DOMAIN[/UNIT]"
        ~doc:
          "Check one domain (`payments`) or one unit (`payments/charge_svc`). A name \
           that matches nothing fails closed and says what does, rather than selecting \
           nothing and reporting success.")
;;

let cmd =
  Cmd.v
    (Cmd.info
       "check"
       ~doc:"Validate Sol workload declarations without Docker or Kubernetes.")
    Term.(const run $ scope_arg)
;;
