type trigger =
  | Cron
  | Lambda

module type FN = sig
  val trigger : trigger
  val run : unit -> (unit, string) result
end

type run_error =
  [ `Config of string
  | `Run of string
  | `Signalled
  ]

val run_error_to_string : run_error -> string

module Make (F : FN) : sig
  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> ?pushgateway_url:string
    -> ?job:string
    -> ?ot:Sol_obs.t
    -> ?stop:unit Eio.Promise.t
    -> unit
    -> (unit, run_error) result
end
