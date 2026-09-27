type spec =
  { name : string
  ; namespace : string
  ; target : string
  ; local_port : int
  ; remote_port : int
  }

val write_record : spec -> (unit, string) result
val records : unit -> spec list * string list
val is_running : string -> bool
val stop : string -> unit
val stop_all : unit -> unit
val start : ctx:Sol_cli_kube_destination.context -> spec -> (unit, string) result

type liveness =
  | Alive
  | Dead of
      { log : string
      ; log_tail : string list
      }

val check_alive : name:string -> liveness
val replace_conflicting : local_port:int -> namespace:string -> target:string -> spec list
