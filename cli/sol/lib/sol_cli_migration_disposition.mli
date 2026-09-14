(** A migration's authored expand/contract disposition (DEC-018, FEAT-066).

    Forward-only, expand/contract migrations let old application code keep
    working against a newer schema, which is what makes `sol rollback` safe:
    an [Expand] migration never blocks restoring an older release, but a
    [Contract] migration does, because it removes something the older release
    depends on.

    The disposition is authored metadata about the migration file itself, not
    part of its identity — so it lives in the file's own header rather than
    its filename or a separate manifest that could drift out of sync. There is
    no [Unknown] variant: a migration that does not declare one is a failure to
    establish the authored contract, not a legitimate third disposition, so
    decoding fails closed instead of guessing. *)
type t =
  | Expand
  | Contract

val to_string : t -> string

(** [of_file_content contents] decodes the disposition from a migration file's
    own text. The tag must be the file's first non-blank line, exactly
    [-- sol:disposition expand] or [-- sol:disposition contract] (surrounding
    whitespace tolerated) — deliberately not a substring search over the whole
    file, so an incidental mention later in the SQL can never be mistaken for
    the authored header. A missing or unrecognised tag is an [Error] naming
    why, never a default. *)
val of_file_content : string -> (t, string) result

(** [read_file ~path] reads [path] and decodes its disposition via
    {!of_file_content}. Returns [Error] (never raises) if the file cannot be
    read. *)
val read_file : path:string -> (t, string) result
