let () =
  (* Root-discovery chdir (OBS-013) is scoped to sol status/logs/open's own
     workspace_name(), not done here globally -- a global chdir here would
     also change relative-path resolution for sol deploy --emit-to/
     --emit-plan-to, sol migrate --dir, and sol cloud tf --var-file, none
     of which asked for workspace-root-relative behavior (OBS-017). *)
  let cmd =
    Cmdliner.Cmd.group
      (Cmdliner.Cmd.info
         "sol"
         ~version:Version.v
         ~doc:"Sol platform CLI — scaffold, run, and deploy Sol services")
      [ Sol_cli_cmd_new.cmd
      ; Cmd_check.cmd
      ; Cmd_local.cmd
      ; Cmd_plan.cmd
      ; Cmd_up.cmd
      ; Cmd_deploy.cmd
      ; Cmd_status.cmd
      ; Cmd_logs.cmd
      ; Cmd_open.cmd
      ; Cmd_migrate.cmd
      ; Cmd_rollback.cmd
      ; Cmd_secret.cmd
      ; Cmd_target.cmd
      ; Cmd_releases.cmd
      ; Cmd_cloud.cmd
      ]
  in
  exit (Cmdliner.Cmd.eval cmd)
;;
