open Cmdliner

let run filter_path =
  let findings = Sol_cli_check.run ~filter_path () in
  List.iter (fun f -> Printf.eprintf "%s\n" (Sol_cli_check.finding_to_string f)) findings;
  if Sol_cli_check.has_errors findings then
    exit 1
  else
    Printf.printf "sol check: ok\n"

let path_arg =
  Arg.(value & pos 0 (some string) None &
       info [] ~docv:"PATH"
         ~doc:"Service path to check (default: all services in workspace)")

let cmd =
  Cmd.v
    (Cmd.info "check" ~doc:"Validate Sol workload declarations without Docker or Kubernetes.")
    Term.(const run $ path_arg)
