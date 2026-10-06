type t
type request

val create : unit -> t
val ready : t -> bool
val begin_shutdown : t -> unit
val begin_draining : t -> unit
val begin_request : t -> request option
val finish_request : request -> unit
val in_flight : t -> int
