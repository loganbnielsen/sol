module type HANDLER = sig
  val routes : Route.t list
end

type run_error = [ `Config of string ]

val run_error_to_string : run_error -> string

module Make (H : HANDLER) : sig
  val run :
    env:
      < net : _ Eio.Net.t
      ; clock : _ Eio.Time.clock
      ; fs : Eio.Fs.dir_ty Eio.Path.t
      ; .. > ->
    ?port:int ->
    ?metrics_auth:Auth.level ->
    ?ot:Sol_obs.t
      (** Observability handle. When provided, [sol_svc_requests_total] and
          [sol_svc_request_duration_seconds] are emitted automatically, and the
          built-in [/metrics] endpoint renders from the same handle. *) ->
    ?max_body_bytes:int ->
    ?drain_timeout_s:float ->
    ?stop:unit Eio.Promise.t
      (** External stop signal. Resolve to request graceful shutdown; in-flight
          requests get up to [drain_timeout_s] before forced cancellation. *) ->
    ?on_listen:(int -> unit) ->
    unit ->
    (unit, run_error) result
end

val run :
  Route.t list ->
  env:
    < net : _ Eio.Net.t
    ; clock : _ Eio.Time.clock
    ; fs : Eio.Fs.dir_ty Eio.Path.t
    ; .. > ->
  ?port:int ->
  ?metrics_auth:Auth.level ->
  ?ot:Sol_obs.t ->
  ?max_body_bytes:int ->
  ?drain_timeout_s:float ->
  ?stop:unit Eio.Promise.t ->
  ?on_listen:(int -> unit) ->
  unit ->
  (unit, run_error) result
(** Functional alternative to [Make(H).run]. Equivalent to
    [Make(struct let routes = routes end).run]. Use when routes are defined
    inline or captured from a closure, avoiding the module boilerplate. *)
