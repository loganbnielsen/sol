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

val start
  :  ?supervisor:string
  -> ctx:Sol_cli_kube_destination.context
  -> spec
  -> (unit, string) result

val max_fail_streak : int
val quick_fail_threshold_s : float
val next_fail_streak : streak:int -> elapsed_s:float -> int
val exhausted : int -> bool
val dispatch_if_supervisor : unit -> unit

type liveness =
  | Alive
  | Dead of
      { log : string
      ; log_tail : string list
      }

val check_alive : name:string -> liveness

type readiness_error =
  | Not_started of string
  | Port_conflict of string
  | Not_ready of
      { log : string
      ; log_tail : string list
      }

val readiness_error_to_string : readiness_error -> string

val ensure_ready
  :  ?supervisor:string
  -> ?timeout_s:float
  -> ?interval_s:float
  -> ctx:Sol_cli_kube_destination.context
  -> spec
  -> (unit, readiness_error) result

val replace_conflicting : local_port:int -> namespace:string -> target:string -> spec list
