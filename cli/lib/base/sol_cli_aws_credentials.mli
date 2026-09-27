type t =
  { access_key_id : string
  ; secret_access_key : string
  ; session_token : string option
  ; principal : string
  }

val parse_env_format : string -> (string * string * string option) option

val resolve
  :  run:(string list -> string option)
  -> profile:string option
  -> (t, string) result

val install : t -> unit

val unresolved_message
  :  operation:string
  -> profile:string option
  -> leaves_target_standing:bool
  -> detail:string
  -> string
