(** Returns [true] if [dir] looks like a Sol home (source checkout or release bundle).
    Checks for the two sentinel files that must exist in any valid Sol root:
      - [framework/sol-svc/lib/dune]
      - [framework/kafka-eio-service/lib/dune] *)
val is_sol_home : string -> bool

(** [find_ancestor pred dir] walks up the directory tree from [dir], returning
    [Some d] for the first ancestor directory (including [dir] itself) where
    [pred d] is true, or [None] if the filesystem root is reached without a match. *)
val find_ancestor : (string -> bool) -> string -> string option

(** Infers the Sol home directory.
    1. Checks [$SOL_HOME] if set to a non-empty value — returns [Some dir] if
       it passes [is_sol_home], [None] if it doesn't (an explicit but wrong
       override is treated as an error, not silently ignored).
    2. Otherwise (unset, or set to [""] — OCaml's [Unix.putenv] has no
       portable way to truly unset a variable, so an empty string is treated
       the same as unset) walks up from the directory containing the running
       binary. *)
val infer_sol_home : unit -> string option

val parse_domain_name : string -> ((string * string), string) result

val new_workspace : string -> unit
val new_svc       : string -> unit
val new_worker    : string -> unit
val new_fn        : string -> unit
val new_event     : string -> unit
val cmd           : unit Cmdliner.Cmd.t
