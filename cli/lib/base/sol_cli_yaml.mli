type t

val string : string -> t
val quoted : string -> t
val literal : string -> t
val int : int -> t
val bool : bool -> t
val map : (string * t) list -> t
val list : t list -> t
val plain_safe : string -> bool

type document

val document : ?comments:string list -> t -> document
val to_string : t -> string
val render : document list -> string
