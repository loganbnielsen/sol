(** The aws CLI's failures, read in one place (REFAC-136). *)

(** [error_code text]: the service error code in the aws CLI's
    `An error occurred (<Code>) when calling the <Operation> operation: ...`.
    The code is what a caller may branch on; the prose around it is not, and the
    message a caller reports is always the CLI's own text. *)
val error_code : string -> string option
