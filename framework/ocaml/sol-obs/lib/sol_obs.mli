type t

type level = Obs_eio.level =
  | Debug
  | Info
  | Warn
  | Error

type span = Obs_eio.span

val taxonomy : (string * string) list
val taxonomy_labels : string list

val of_env
  :  sw:Eio.Switch.t
  -> net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> mono_clock:_ Eio.Time.Mono.t
  -> service:string
  -> ?context:(string * string) list
  -> unit
  -> t

val flush : ?timeout:float -> t -> unit
val log_debug : t -> ?fields:(string * string) list -> string -> unit
val log_info : t -> ?fields:(string * string) list -> string -> unit
val log_warn : t -> ?fields:(string * string) list -> string -> unit
val log_error : t -> ?fields:(string * string) list -> string -> unit
val with_span : t -> ?parent:Obs_trace.t -> string -> (span -> 'a) -> 'a
val log : span -> level -> ?fields:(string * string) list -> string -> unit
val current_trace_context : span -> Obs_trace.t
val trace_id_string : Obs_trace.t -> string

val counter
  :  t
  -> name:string
  -> help:string
  -> label_names:string list
  -> Obs_eio.counter_fn

val gauge : t -> name:string -> help:string -> label_names:string list -> Obs_eio.gauge_fn

val histogram
  :  t
  -> name:string
  -> help:string
  -> label_names:string list
  -> Obs_eio.histogram_fn

val with_context : t -> (string * string) list -> t
val obs_eio : t -> Obs_eio.t
val metrics_renderer : t -> unit -> string
val backend_and_renderer : t -> Obs_eio.backend * (unit -> string)
