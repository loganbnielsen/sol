type t = (string * string) list

val parse : ?source:string -> string -> (t, string) result
val load : root:string -> unit_address:string -> (t, string) result
