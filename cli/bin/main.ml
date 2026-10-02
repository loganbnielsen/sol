let () =
  Sol_cli_report.install_terminal ();
  Sol_cli_supervised.dispatch_if_supervisor ();
  Sol_cli_port_forward.dispatch_if_supervisor ();
  let cmd =
    Cmdliner.Cmd.group
      (Cmdliner.Cmd.info
         "sol"
         ~version:(Option.value Sol_cli_build_info.release_version ~default:Version.v)
         ~doc:"Sol platform CLI — scaffold, run, and deploy Sol services")
      [ Sol_cli_cmd_new.cmd
      ; Cmd_check.cmd
      ; Cmd_local.cmd
      ; Cmd_plan.cmd
      ; Cmd_up.cmd
      ; Cmd_deploy.cmd
      ; Cmd_status.cmd
      ; Cmd_logs.cmd
      ; Cmd_fn.cmd
      ; Cmd_open.cmd
      ; Cmd_migrate.cmd
      ; Cmd_rollback.cmd
      ; Cmd_secret.cmd
      ; Cmd_target.cmd
      ; Cmd_releases.cmd
      ; Cmd_deployments.cmd
      ; Cmd_assets.cmd
      ; Cmd_alert.cmd
      ; Cmd_cloud.cmd
      ; Cmd_uninstall.cmd
      ]
  in
  exit (Cmdliner.Cmd.eval cmd)
;;
