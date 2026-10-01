module type EVENT = sig
  type t

  val kind : t -> string
  val kinds : string list
  val encode : t -> string
end

type run_error =
  [ `Config of string
  | `Database of string
  ]

val run_error_to_string : run_error -> string

type publication =
  { kind : string
  ; key : string
  ; ord : int64
  ; payload : string
  }

val publish
  :  Pg_db.tx
  -> key:string
  -> ord:int64
  -> payload:string
  -> kind:string
  -> (unit, Pg_error.t) result

module Make (E : EVENT) : sig
  val publish : Pg_db.tx -> key:string -> ord:int64 -> E.t -> (unit, Pg_error.t) result

  val relay
    :  env:(_, _, _, _) Sol_env.timed
    -> pool:Pg_db.pool
    -> publish:(publication -> (unit, string) result)
    -> ?poll_interval_s:float
    -> ?batch:int
    -> ?ot:Sol_obs.t
    -> ?metrics_port:int
    -> ?on_ready:(unit -> unit)
    -> ?stop:unit Eio.Promise.t
    -> unit
    -> (unit, run_error) result
end

module For_testing : sig
  val pending
    :  Pg_db.pool
    -> ?limit:int
    -> unit
    -> ((string * int64) list, Pg_error.t) result

  val pending_count : Pg_db.pool -> (int, Pg_error.t) result
end
