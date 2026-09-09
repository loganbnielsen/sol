type method_ = [ `GET | `POST | `PUT | `PATCH | `DELETE ]

type t = {
  method_ : method_;
  path : string;
  headers : Http.Header.t;
  params : (string * string) list;
  uri : Uri.t;
  body : string;
  auth : Auth.context;
  trace_ctx : Obs_trace.t option;
      (** W3C [traceparent] extracted from the incoming request headers. Pass as
          [?parent] to [Obs_eio.with_span] to link child spans to the caller. *)
}

val param : t -> string -> string option
(** [param req "id"] — look up an extracted path parameter. *)

val param_exn : t -> string -> string
(** [param_exn req "id"] — look up a path parameter; raises [Not_found] if
    absent. Safe to call when the route pattern guarantees the parameter exists.
*)

val query_param : t -> string -> string option
(** [query_param req "page"] — first value of a query string parameter. *)

val query_params : t -> string -> string list
(** [query_params req "tags"] — all values for a repeated query parameter. *)

val header : t -> string -> string option
(** [header req "content-type"] — case-insensitive header lookup. *)
