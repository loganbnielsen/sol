open Cmdliner
open Result.Syntax

let run check =
  let* workspace = Sol_cli_workspace.enter_cwd () in
  let root = workspace.Sol_cli_workspace.root in
  let* written = Sol_cli_contract_gen.generate ~root ~check |> Sol_cli_exit.of_msg in
  if check
  then Printf.printf "sol contract: the checked-in bindings match the declaration\n"
  else (
    List.iter (fun path -> Printf.printf "wrote %s\n" path) written;
    Printf.printf "sol contract: generated %d file(s)\n" (List.length written));
  Ok ()
;;

let check_arg =
  Arg.(
    value
    & flag
    & info
        [ "check" ]
        ~doc:
          "Do not write; fail if the checked-in bindings are missing or differ from the \
           declarative contract.")
;;

let generate =
  Cmd.v
    (Cmd.info
       "generate"
       ~doc:"Generate each scope's language bindings from its declarative event contract.")
    Term.(const Sol_cli_exit.exit_on $ (const run $ check_arg))
;;

let cmd =
  Cmd.group
    (Cmd.info "contract" ~doc:"Work with the workspace's declarative event contract.")
    [ generate ]
;;
