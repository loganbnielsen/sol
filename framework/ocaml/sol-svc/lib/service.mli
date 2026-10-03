module type HANDLER = sig
  val routes : Route.t list
end

type run_error = [ `Config of string ]

val run_error_to_string : run_error -> string

module Make (H : HANDLER) : sig
  val run
    :  env:
         < net : _ Eio.Net.t
         ; clock : _ Eio.Time.clock
         ; fs : Eio.Fs.dir_ty Eio.Path.t
         ; .. >
    -> ?port:int
    -> ?metrics_auth:Auth.level
    -> ?ot:Sol_obs.t
    -> ?max_body_bytes:int
    -> ?drain_timeout_s:float
    -> ?shutdown_delay_s:float
    -> ?stop:unit Eio.Promise.t
    -> ?on_listen:(int -> unit)
    -> unit
    -> (unit, run_error) result
end

val run
  :  Route.t list
  -> env:
       < net : _ Eio.Net.t
       ; clock : _ Eio.Time.clock
       ; fs : Eio.Fs.dir_ty Eio.Path.t
       ; .. >
  -> ?port:int
  -> ?metrics_auth:Auth.level
  -> ?ot:Sol_obs.t
  -> ?max_body_bytes:int
  -> ?drain_timeout_s:float
  -> ?shutdown_delay_s:float
  -> ?stop:unit Eio.Promise.t
  -> ?on_listen:(int -> unit)
  -> unit
  -> (unit, run_error) result

module For_testing : sig
  val respond_or_500 : (unit -> Response.t) -> Response.t

  val dispatch
    :  ?read_api_key:(unit -> string option)
    -> ?fetch_jwks:(string -> (Jose.Jwks.t, string) result)
    -> routes:Route.t list
    -> Http.Request.t
    -> Cohttp_eio.Body.t
    -> Response.t
end
