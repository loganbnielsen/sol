type t =
  { status  : int
  ; headers : (string * string) list
  ; body    : string
  }

val ok            : ?headers:(string * string) list -> string -> t
val created       : ?headers:(string * string) list -> string -> t
val no_content    : t

val bad_request      : string -> t
val unauthorized     : t
val forbidden        : t
val not_found        : t
val unprocessable    : string -> t
val payload_too_large : t
val internal_error   : string -> t

val json : ?status:int -> ?headers:(string * string) list -> string -> t
