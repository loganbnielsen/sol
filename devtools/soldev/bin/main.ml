let () =
  let cmd =
    Cmdliner.Cmd.group
      (Cmdliner.Cmd.info
         "soldev"
         ~version:"dev"
         ~doc:"Sol internal developer CLI — pipeline operations for Sol development")
      [ Cmd_pipeline.cmd ]
  in
  exit (Cmdliner.Cmd.eval cmd)
;;
