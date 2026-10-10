type t = (string * string) list

val parse : string -> (t, string) result
val load : root:string -> (t, string) result
