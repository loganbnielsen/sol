open Cmdliner

let cmd =
  Cmd.group
    (Cmd.info "cloud"
       ~doc:"Provision cloud infrastructure")
    [ Cmd_cloud_tf.plan_cmd
    ; Cmd_cloud_tf.apply_cmd
    ; Cmd_cloud_tf.destroy_cmd
    ]
