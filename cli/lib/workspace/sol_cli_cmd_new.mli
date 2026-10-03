val parse_domain_name : string -> (string * string, string) result
val new_workspace : string -> (unit, string) result
val new_svc : ?language:Sol_cli_compat.language -> string -> (unit, string) result
val new_worker : ?language:Sol_cli_compat.language -> string -> (unit, string) result
val new_fn : ?language:Sol_cli_compat.language -> string -> (unit, string) result
val new_event : string -> (unit, string) result
val cmd : unit Cmdliner.Cmd.t
