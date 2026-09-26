(** The CLI edge's one way to turn a failed [result] into an exit (REFAC-111).

    A command body works in [result]s; at the command boundary a failure is
    printed as [error: <message>] on stderr and the process exits 1. This is
    OCaml's missing [getOrElse]-with-effect, written once instead of as a
    hand-written [match] in every command. *)

(** [or_exit r] is [x] for [Ok x]; for [Error msg] it prints [error: msg] and
    exits 1. *)
val or_exit : ('a, string) result -> 'a

(** [or_exit_with to_string r] is [or_exit] for a typed error. *)
val or_exit_with : ('e -> string) -> ('a, 'e) result -> 'a

(** {1 Failures carried to the top (REFAC-115, REFAC-117)}

    A command's [run] returns [(unit, failure) result] and composes its steps
    with [let*]; the Cmdliner term converts it to a process exit once, with
    {!exit_on}. A failure carries the exact text to print and the exit code, so
    multi-line guidance and non-1 codes survive unchanged. *)

type failure =
  { text : string (** Printed verbatim to stderr. *)
  ; code : int
  }

(** [error msg] is the usual failure: [error: <msg>], exit 1 unless [code]. *)
val error : ?code:int -> string -> failure

(** [failure text] prints [text] exactly as given (exit 1 unless [code]). *)
val failure : ?code:int -> string -> failure

(** [exit_on r]: nothing for [Ok ()]; otherwise print the failure's text and
    exit with its code. The one place a command's [result] becomes an exit. *)
val exit_on : (unit, failure) result -> unit
