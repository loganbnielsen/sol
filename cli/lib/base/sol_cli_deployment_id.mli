type t

val create : now:float -> entropy:string -> t
val random_entropy : unit -> string
val to_string : t -> string
val of_string : string -> (t, string) result
