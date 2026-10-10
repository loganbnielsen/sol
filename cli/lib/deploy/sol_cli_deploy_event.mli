type t =
  { workspace : string
  ; env : string
  ; domain : string
  ; service : string
  ; primitive : string
  ; release_id : Sol_cli_release_id.t
  }

val fields : t -> (string * string) list
val message : t -> string

type push_url_decision =
  | Explicit of string
  | Auto_detect
  | Skip of string

val resolve_push_url
  :  backend:Sol_cli_observability_backend.backend
  -> explicit_url:string option
  -> push_url_decision
