(** What library code tells the operator, without deciding where it goes
    (REFAC-135).

    A library function reports progress, a result it produced, a warning or an
    error through these; it never writes to stdout or stderr itself. The one
    reporter that renders them to the terminal is installed at the CLI's edge
    ([main.ml]), and a test installs {!collect} instead to assert on what was
    reported. Underneath is the [logs] library, the established OCaml shape for
    exactly this split: a library emits, the application reports.

    Each message carries its own text, prefix included ("warning: …"), and is one
    line or block; the terminal reporter adds the newline. The format arguments
    are [Printf]'s, not [Format]'s. *)

(** Progress and results, for stdout. *)
val app : ('a, unit, string, unit) format4 -> 'a

(** A warning: something the operator should know that does not fail the run. *)
val warn : ('a, unit, string, unit) format4 -> 'a

(** An error report that accompanies a failure the caller returns. *)
val err : ('a, unit, string, unit) format4 -> 'a

(** [app_block text] / [err_block text]: a block of text that already ends in a
    newline (a rendered report, a captured log), reported without doubling it. *)
val app_block : string -> unit

val err_block : string -> unit

(** The terminal reporter: [app] to stdout, [warn]/[err] to stderr, each message
    followed by a newline and flushed. *)
val terminal : Logs.reporter

(** [install_terminal ()] makes {!terminal} the reporter. Called once, at the
    CLI's edge. *)
val install_terminal : unit -> unit

(** [collect f]: run [f] with a reporter that records instead of printing, and
    return its result with what it reported, in order. *)
val collect : (unit -> 'a) -> 'a * (Logs.level * string) list
