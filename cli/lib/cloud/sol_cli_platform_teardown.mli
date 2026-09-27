val kinds_of_api_resources : string -> string list

val unserved_of_show_json
  :  served:string list
  -> string
  -> ((string * string) list, string) result

val absent : (string * string) list -> bool

val destroy
  :  run_log:Sol_cli_run_log.t
  -> env:(string * string) list
  -> chdir:string
  -> vars:string list
  -> (unit, string) result
