type method_ =
  [ `GET
  | `POST
  | `PUT
  | `PATCH
  | `DELETE
  ]

type t =
  { method_ : method_
  ; path : string
  ; headers : Http.Header.t
  ; params : (string * string) list
  ; uri : Uri.t
  ; body : string
  ; auth : Auth.context
  ; trace_ctx : Obs_trace.t option
  }

val param : t -> string -> string option
val param_exn : t -> string -> string
val query_param : t -> string -> string option
val query_params : t -> string -> string list
val header : t -> string -> string option
