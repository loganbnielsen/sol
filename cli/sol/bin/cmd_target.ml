(* sol target — inspect a deployment target as a target (FEAT-062).

   Offline by default. `--check` probes the cluster, and it is opt-in rather than
   automatic because the target summary is also what a user reads while
   *diagnosing* an unreachable cluster: a command that blocks on a timeout
   before printing anything is least useful exactly when it is most needed. *)

let available_target_paths () =
  let open Sol_cli_fs_walk in
  let join = Filename.concat in
  match dirs "sol" with
  | Error _ -> []
  | Ok envs ->
    envs
    |> List.concat_map (fun env ->
      match dirs (join "sol" env) with
      | Error _ -> []
      | Ok providers ->
        providers
        |> List.concat_map (fun provider ->
          match files (join (join "sol" env) provider) with
          | Error _ -> []
          | Ok files ->
            files
            |> List.filter_map (fun file ->
              match Filename.check_suffix file ".yml" with
              | true ->
                Some
                  (Printf.sprintf
                     "%s/%s/%s"
                     env
                     provider
                     (Filename.chop_suffix file ".yml"))
              | false -> None)))
;;

let print_available () =
  match available_target_paths () with
  | [] -> Printf.eprintf "no targets found: expected sol/<env>/<provider>/<region>.yml\n"
  | paths -> Printf.eprintf "available targets:\n  %s\n" (String.concat "\n  " paths)
;;

(* The only part that touches a cluster, and only when asked to.

   [Sol_cli_kubectl.probe] answers yes/no and does not surface the reason, so the
   message says what is known and names the command that would explain it,
   rather than inventing a cause. The reason deliberately does not repeat the
   context: the default rendering hides it, so an "unreachable" line that leaked
   it would undo that rule through the back door. *)
let kubernetes_status ~check (target : Sol_cli_config.target) =
  match Sol_cli_config.destination_of_target target with
  | Error _ -> Sol_cli_target_report.Not_configured
  | Ok destination ->
    let context = destination.context in
    if not check
    then Sol_cli_target_report.Configured context
    else (
      let args = Sol_cli_kube_destination.kubectl_args destination @ [ "cluster-info" ] in
      if Sol_cli_kubectl.probe ~args
      then Sol_cli_target_report.Reachable context
      else
        Sol_cli_target_report.Unreachable
          ( context
          , "no response from the cluster; `sol target show --verbose` prints the \
             context to probe by hand" ))
;;

(* Positional, not labelled: cmdliner's [Term.const] applies its arguments in
   order, so a labelled function cannot be used directly. *)
let show target verbose json check =
  match target with
  | None ->
    Printf.eprintf "sol target show needs a target — which one?\n\n";
    print_available ();
    exit 1
  | Some target ->
    (match Sol_cli_config.load_for_target ~target with
     | Error e ->
       Printf.eprintf "%s\n\n" (Sol_cli_config.error_to_string e);
       print_available ();
       exit 1
     | Ok config ->
       (match Sol_cli_config.target config with
        | None ->
          Printf.eprintf "target %s did not resolve to a target configuration\n" target;
          exit 1
        | Some target_config ->
          let status = kubernetes_status ~check target_config in
          if json
          then
            print_endline
              (Yojson.Safe.to_string
                 (Sol_cli_target_report.to_json ~verbose target_config status))
          else
            Sol_cli_target_report.rows ~verbose target_config status
            |> List.iter (fun (label, value) -> Printf.printf "%-13s %s\n" label value)))
;;

open Cmdliner

let target_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "target" ]
        ~docv:"ENV/PROVIDER/REGION"
        ~doc:
          "The target to show, as a path (e.g. `prod/aws/us-east-1`). Required: there is \
           no current target, and no default (DEC-016).")
;;

let verbose_arg =
  Arg.(
    value
    & flag
    & info
        [ "verbose"; "v" ]
        ~doc:
          "Also show where the target sits and the raw kube-context Sol will use. The \
           context is hidden by default because it is a mechanism, not the target's \
           identity (DEC-020).")
;;

let json_arg = Arg.(value & flag & info [ "json" ] ~doc:"Print the same fields as JSON.")

let check_arg =
  Arg.(
    value
    & flag
    & info
        [ "check" ]
        ~doc:
          "Probe the cluster and report whether it is reachable. Off by default: the \
           summary is also what you read while diagnosing an unreachable cluster, so it \
           must not block before printing.")
;;

let show_cmd =
  let doc = "Show a deployment target" in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Prints a target as a target — provider, region, cluster, registry, base domain \
         — and says whether Sol can reach its cluster. Nothing is inferred: an unknown \
         or missing target fails closed and lists what exists."
    ]
  in
  Cmd.v
    (Cmd.info "show" ~doc ~man)
    Term.(const show $ target_arg $ verbose_arg $ json_arg $ check_arg)
;;

let cmd = Cmd.group (Cmd.info "target" ~doc:"Inspect deployment targets") [ show_cmd ]
