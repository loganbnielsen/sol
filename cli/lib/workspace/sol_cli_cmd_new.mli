val parse_domain_name : string -> (string * string, string) result
val new_workspace : string -> unit
val new_svc : string -> unit
val new_worker : string -> unit
val new_fn : string -> unit
val new_event : string -> unit
val cmd : unit Cmdliner.Cmd.t
