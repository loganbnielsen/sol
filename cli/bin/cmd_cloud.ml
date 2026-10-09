open Cmdliner

let cmd =
  Cmd.group
    (Cmd.info "cloud" ~doc:"Inspect or destroy a target's Sol-owned cloud resources")
    [ Cmd_cloud_tf.destroy_cmd; Cmd_cloud_tf.reconcile_cmd ]
;;
