(** The destination a command runs against, resolved from how the command named
    it (REFAC-088).

    One policy, two entry points: `sol local <command>` resolves to Sol's own
    local cluster; `sol <command> --target <t>` resolves through that target's
    configuration. A top-level command with no target is an error whose message
    names the local spelling of the same command -- never an ambient
    fallback (DEC-020). *)

val resolve
  :  command:string
  -> local:bool
  -> target:string option
  -> (Sol_cli_kube_destination.context, string) result
