type error = [ `Config of string ]

val error_to_string : error -> string

(** Env var Sol injects for a declared call target, e.g. [checkout_svc] ->
    [CHECKOUT_SVC_URL]. *)
val env_var : string -> string

val url : string -> (Uri.t, error) result

val headers
  :  env:< fs : Eio.Fs.dir_ty Eio.Path.t ; .. >
  -> ?trace_ctx:Obs_trace.t
  -> ?headers:(string * string) list
  -> peer:string
  -> unit
  -> ((string * string) list, error) result
