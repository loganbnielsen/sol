val declared_in : (string * string) list -> (string list, string) result
val declared : root:string -> (string list, string) result

val refuse_on_command_line
  :  sensitive:string list
  -> vars:string list
  -> (unit, string) result
