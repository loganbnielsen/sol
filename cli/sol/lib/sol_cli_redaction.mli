(** Secret-safe rendering at process and log boundaries. *)

(** [connection_error ~url text] removes the password component of [url]
    wherever a downstream database error reproduced it.  The user, host, port,
    path, query and fragment remain visible for diagnosis.  If [url] is not a
    credential-bearing URI, [text] is returned unchanged. *)
val connection_error : url:string -> string -> string
