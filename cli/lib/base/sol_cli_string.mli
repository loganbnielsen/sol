val is_blank : string -> bool
val non_blank : string -> string option
val non_blank_opt : string option -> string option
val non_empty : string option -> string option
val env : string -> string option
val contains : needle:string -> string -> bool
