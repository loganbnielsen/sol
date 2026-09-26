val parse_domain_name : string -> (string * string, string) result

(** The scaffolds: each writes its files and prints what it did, or says why it
    could not (an existing path, a malformed [DOMAIN/NAME]) before writing
    anything (REFAC-115). *)
val new_workspace : string -> (unit, string) result

val new_svc : string -> (unit, string) result
val new_worker : string -> (unit, string) result
val new_fn : string -> (unit, string) result
val new_event : string -> (unit, string) result
val cmd : unit Cmdliner.Cmd.t
