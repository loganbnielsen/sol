open Cmdliner

(* A requested scope must resolve, or the command fails. That rule is the point
   of the vocabulary (FEAT-061): a name that matches nothing is an error naming
   what exists, never a quiet empty selection that reports success. *)
let fail message =
  Printf.eprintf "sol check: %s\n" message;
  exit 2
;;

(* [scope] names what to check. There is no positional selector any more
   (FEAT-064): a name and a directory are different concepts, and one argument
   meaning "maybe one, maybe the other" is exactly what made selection
   unpredictable. Resolving a scope needs discovery, because the kind of a unit
   comes from what is on disk rather than from what the user typed. *)
let run scope =
  let findings =
    match scope with
    | None -> Sol_cli_check.run ~filter_path:None ()
    | Some requested ->
      let request =
        match Sol_cli_deployment_scope.parse_request ~what:"--scope" (Some requested) with
        | Ok request -> request
        | Error message -> fail message
      in
      let services =
        match Sol_cli_manifest.discover_services_result ~filter_path:None with
        | Ok services -> services
        | Error _ ->
          fail "--scope needs a workspace to resolve against (no app/ directory here)"
      in
      (* Discovery speaks its own service type; the vocabulary speaks [named]. The
         adaptation lives at the command rather than inside the vocabulary, which
         is why the vocabulary's tests needed no change when this wiring landed —
         binding it to either record would have made that record the centre of the
         design.

         The pair carries [dir] because the resolver identifies a unit by *name*,
         while the check machinery is path-based: the name is what the user says,
         the directory is how the thing is reached. *)
      let discovered =
        List.map
          (fun (svc : Sol_cli_manifest.service) ->
             ( { Sol_cli_deployment_scope.domain = svc.domain
               ; name = svc.name
               ; kind =
                   (match svc.primitive with
                    | Svc -> Service
                    | Worker -> Worker
                    | Fn -> Function)
               }
             , svc.dir ))
          services
      in
      let units = List.map fst discovered in
      (* Deliberately not parenthesised: binding the inputs first leaves one match
         in tail position, where none of the nesting parens are needed. *)
      (match Sol_cli_deployment_scope.resolve ~what:"--scope" request units with
       | Error message -> fail message
       | Ok (_, Sol_cli_deployment_scope.Selected selected) ->
         selected
         |> List.filter_map (fun unit -> List.assoc_opt unit discovered)
         |> List.concat_map (fun dir -> Sol_cli_check.run ~filter_path:(Some dir) ())
       | Ok (_, Sol_cli_deployment_scope.Empty) ->
         (* Reading is allowed to find nothing: an empty workspace is an answer, not
           a failure. The mutating commands decide the opposite, which is why
           emptiness is reported by the resolver rather than judged by it. *)
         [])
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
