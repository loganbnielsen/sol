type install =
  { label : string
  ; run : unit -> (unit, string) result
  }

val max_in_flight_default : int
val run_bounded : ?max_in_flight:int -> install list -> (unit, string) result
