let positional ~doc =
  Cmdliner.Arg.(
    required & pos 0 (some Sol_cli_args.text) None & info [] ~docv:"TARGET" ~doc)
;;

let optional_positional ~doc =
  Cmdliner.Arg.(value & pos 0 (some Sol_cli_args.text) None & info [] ~docv:"TARGET" ~doc)
;;

let flag ~doc =
  Cmdliner.Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info [ "target" ] ~docv:"ENV/PROVIDER/REGION" ~doc)
;;

let required_flag ~doc =
  Cmdliner.Arg.(
    required
    & opt (some Sol_cli_args.text) None
    & info [ "target" ] ~docv:"ENV/PROVIDER/REGION" ~doc)
;;
