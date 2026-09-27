val subst : (string * string) list -> string -> string
val write_file : path:string -> content:string -> (unit, string) result
val normalize : string -> string
val capitalize_name : string -> string
