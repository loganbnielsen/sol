type handler = Request.t -> Response.t

type pattern_segment =
  | Literal of string
  | Param of string

type pattern = private
  { source : string
  ; segments : pattern_segment list
  ; trailing_slash : bool
  }

type t =
  { method_ : Request.method_
  ; pattern : pattern
  ; auth : Auth.level
  ; handler : handler
  }

val parse_pattern : string -> (pattern, string) result
val pattern : string -> pattern
val pattern_to_string : pattern -> string
val parse_request_path : string -> (string list * bool) option
val default_auth : Auth.level
val get : ?auth:Auth.level -> string -> handler -> t
val post : ?auth:Auth.level -> string -> handler -> t
val put : ?auth:Auth.level -> string -> handler -> t
val patch : ?auth:Auth.level -> string -> handler -> t
val delete : ?auth:Auth.level -> string -> handler -> t
