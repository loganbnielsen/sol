(** The CLI edge's one way to turn a failed [result] into an exit (REFAC-111,
    REFAC-115).

    A command's [run] returns [(unit, failure) result] and composes its steps
    with [let*]; the Cmdliner term converts it to a process exit once, with
    {!exit_on}. Nothing below a command's term exits. A failure carries the exact
    text to print and the exit code, so multi-line guidance and non-1 codes
    survive unchanged. *)

type failure =
  { text : string (** Printed verbatim to stderr. *)
  ; code : int
  }

(** [error msg] is the usual failure: [error: <msg>], exit 1 unless [code]. *)
val error : ?code:int -> string -> failure

(** [failure text] prints [text] exactly as given (exit 1 unless [code]). *)
val failure : ?code:int -> string -> failure

(** [reported ()] is a failure the command has already explained (its findings
    are on stderr): nothing more is printed, and it exits 1 unless [code]. *)
val reported : ?code:int -> unit -> failure

(** [of_msg r] is [r] with a message error carried as {!error}: the step of a
    [let*] chain that calls a library function returning [(_, string) result]. *)
val of_msg : ('a, string) result -> ('a, failure) result

(** [of_error to_string r] is {!of_msg} for a typed error. *)
val of_error : ('e -> string) -> ('a, 'e) result -> ('a, failure) result

(** [exit_on r]: nothing for [Ok ()]; otherwise print the failure's text, as a
    complete line (a newline is added only if it lacks one), and exit with its
    code. The one place a command's [result] becomes an exit. *)
val exit_on : (unit, failure) result -> unit
