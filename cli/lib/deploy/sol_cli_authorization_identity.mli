type t

val of_target : Sol_cli_config.target -> (t, string) result
val describe : t -> string
val caller_is_reconciler : t -> principal:string -> (unit, string) result
val environment : t -> ((string * string) list, string) result
