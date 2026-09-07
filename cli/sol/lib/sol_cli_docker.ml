let run_ok = Sol_cli_process.run_ok
let run = Sol_cli_process.run
let cmd = Sol_cli_process.cmd

let build ~tag ~dockerfile ~context =
  run_ok (cmd ["docker"; "build"; "-t"; tag; "-f"; dockerfile; context])

let push ~image_ref =
  run_ok (cmd ["docker"; "push"; image_ref])

let inspect_digest ~image_ref =
  match run (cmd ["docker"; "inspect"; "--format"; "{{index .RepoDigests 0}}"; image_ref]) with
  | Ok r when r.Sol_cli_process.exit_code = 0
           && r.Sol_cli_process.stdout <> ""
           && r.Sol_cli_process.stdout <> "<no value>" ->
    r.Sol_cli_process.stdout
  | _ -> image_ref
