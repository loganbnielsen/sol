type error = [ `Config of string ]
type t

val error_to_string : error -> string
val env_var : string -> string
val token_file_env_var : string -> string

(** The development-only opt-in that lets a bare process use [SOL_API_KEY] when
    no projected identity was declared. Reserved in [sol.toml] and [sol secret
    set]; only local tooling sets it. *)
val plaintext_auth_opt_in : string

module For_codegen : sig
  (** Generated application bindings are the supported way to obtain a peer. *)
  val declared : unit_id:string -> service_name:string -> t
end

val url : t -> (Uri.t, error) result

(** Attach the callee's projected identity as [Authorization: Bearer], or, when
    no projection was declared and the explicit local opt-in is set, the shared
    API key. A declared-but-unreadable projection fails; it never downgrades. *)
val headers
  :  env:< fs : Eio.Fs.dir_ty Eio.Path.t ; .. >
  -> peer:t
  -> ?trace_ctx:Obs_trace.t
  -> ?headers:(string * string) list
  -> unit
  -> ((string * string) list, error) result
