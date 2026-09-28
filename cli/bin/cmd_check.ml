open Cmdliner
open Result.Syntax

let fail message = Sol_cli_exit.failure ~code:2 ("sol check: " ^ message)

let findings_for ~facts = function
  | None -> Ok (Sol_cli_check.run ~facts)
  | Some requested ->
    let* selected =
      Sol_cli_workload_selection.resolve
        ~what:"--scope"
        (Some requested)
        (Sol_cli_workspace_model.services facts)
      |> Result.map_error fail
    in
    Ok (Sol_cli_check.run_services ~facts selected.services)
;;

type outcome =
  { findings : Sol_cli_check.finding list
  ; result : (unit, Sol_cli_exit.failure) result
  }

let inspect scope =
  let* workspace = Sol_cli_workspace.enter_cwd () in
  let* facts =
    Sol_cli_workspace_model.load ~root:workspace.Sol_cli_workspace.root
    |> Sol_cli_exit.of_msg
  in
  let* findings = findings_for ~facts scope in
  let result =
    if Sol_cli_check.has_errors findings then Error (Sol_cli_exit.reported ()) else Ok ()
  in
  Ok { findings; result }
;;

let render { findings; result } =
  let stderr =
    findings
    |> List.map (fun finding -> Sol_cli_check.finding_to_string finding ^ "\n")
    |> String.concat ""
  in
  let stdout = if Result.is_ok result then "sol check: ok\n" else "" in
  stdout, stderr
;;

let run scope =
  let* outcome = inspect scope in
  let stdout, stderr = render outcome in
  Printf.eprintf "%s" stderr;
  Printf.printf "%s" stdout;
  outcome.result
;;

let scope_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
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
    Term.(const Sol_cli_exit.exit_on $ (const run $ scope_arg))
;;
