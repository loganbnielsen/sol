type handler = Request.t -> Response.t

type pattern_segment =
  | Literal of string
  | Param of string

type pattern = private
  { source         : string
  ; segments       : pattern_segment list
  ; trailing_slash : bool
  }

type t =
  { method_  : Request.method_
  ; pattern  : pattern
  ; auth     : Auth.level
  ; handler  : handler
  }

val parse_pattern      : string -> (pattern, string) result
val pattern            : string -> pattern
val pattern_to_string  : pattern -> string

(** Validate and split a request path.
    Returns [None] for malformed paths (consecutive slashes).
    Returns [Some (segments, has_trailing_slash)] for valid paths. *)
val parse_request_path : string -> (string list * bool) option

val get    : string -> auth:Auth.level -> handler -> t
val post   : string -> auth:Auth.level -> handler -> t
val put    : string -> auth:Auth.level -> handler -> t
val patch  : string -> auth:Auth.level -> handler -> t
val delete : string -> auth:Auth.level -> handler -> t
