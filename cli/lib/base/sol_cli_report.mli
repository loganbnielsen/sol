val app : ('a, unit, string, unit) format4 -> 'a
val warn : ('a, unit, string, unit) format4 -> 'a
val err : ('a, unit, string, unit) format4 -> 'a
val app_block : string -> unit
val err_block : string -> unit
val terminal : Logs.reporter
val install_terminal : unit -> unit
val collect : (unit -> 'a) -> 'a * (Logs.level * string) list
