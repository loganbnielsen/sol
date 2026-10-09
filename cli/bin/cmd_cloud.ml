open Cmdliner

let cmd =
  Cmd.group
    (Cmd.info "cloud" ~doc:"Inspect a target's Sol-owned cloud resources")
    [ Cmd_cloud_tf.reconcile_cmd ]
;;
