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
