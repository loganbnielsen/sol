type failure =
  { text : string
  ; code : int
  }

val error : ?code:int -> string -> failure
val failure : ?code:int -> string -> failure
val reported : ?code:int -> unit -> failure
val of_msg : ('a, string) result -> ('a, failure) result
val of_error : ('e -> string) -> ('a, 'e) result -> ('a, failure) result
val exit_on : (unit, failure) result -> unit
