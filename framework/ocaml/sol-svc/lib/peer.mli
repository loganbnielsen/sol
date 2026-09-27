type error = [ `Config of string ]

val error_to_string : error -> string
val env_var : string -> string
val url : string -> (Uri.t, error) result

val headers
  :  env:< fs : Eio.Fs.dir_ty Eio.Path.t ; .. >
  -> ?trace_ctx:Obs_trace.t
  -> ?headers:(string * string) list
  -> unit
  -> ((string * string) list, error) result
