(* REFAC-088 (with FEAT-063): the seam between how a command names its
   destination and the destination it actually runs against.

   `sol local <command>` and `sol <command> --target <t>` are two entry points
   over one resolution policy. The policy is what must agree between them, and
   it lives here -- in the library, not the command modules -- so the policy
   itself is testable rather than only reachable through a live cluster.

   There are exactly two ways to name a destination and no third: falling back
   to "whatever kubectl happens to be pointed at" is the hidden input DEC-020
   removes. A top-level command with no `--target` therefore fails closed, and
   its message names the local spelling of *that same command* so the fix is
   stated rather than merely refused. *)

let resolve ~command ~local ~target =
  if local
  then Ok Sol_cli_kube_destination.local_context
  else (
    match target with
    | Some path ->
      (match Sol_cli_config.load_for_target ~target:path with
       | Error e -> Error (Sol_cli_config.error_to_string e)
       | Ok cfg ->
         (match cfg.Sol_cli_config.target with
          | None ->
            Error
              (Printf.sprintf
                 "target %s declares no kube_context, so Sol cannot tell which cluster \
                  to reach; add `kube_context:` to its target file"
                 path)
          | Some t ->
            (match Sol_cli_config.destination_of_target t with
             | Error msg -> Error msg
             | Ok destination ->
               Ok (Sol_cli_kube_destination.context_of_destination destination))))
    | None ->
      Error
        (Printf.sprintf
           "`sol %s` needs --target <env>/<provider>/<region> to know which cluster to \
            reach; for Sol's own local cluster use `sol local %s`"
           command
           command))
;;
