type infra_requirements =
  { kafka : bool
  ; postgres : bool
  ; loki : bool
  ; prometheus : bool
  ; tempo : bool
  }

(** Count [.sql] files in [dir/db/migrations]. Returns 0 if the directory does
    not exist. Used by [sol up] to warn users about unapplied migrations. *)
val pending_migration_count : dir:string -> int

(** Walk all [dune] files under [dir] and detect which Sol infrastructure
    libraries the workspace depends on. Used by [sol dev up] to start exactly
    the infra the workspace needs. *)
val scan : dir:string -> infra_requirements

(** Walk up from [dir] (inclusive) looking for the nearest ancestor containing
    an [app/] subdirectory -- Sol's workspace-root marker, already used by
    [discover_services]/[discover_domains]. Returns [None] when no such ancestor
    exists (e.g. before [sol new]'s first scaffold), so callers can fall back to
    today's behavior rather than erroring. Used by [main.ml] to make every [sol]
    command deterministic from any directory inside the workspace, not just the
    root. *)
val find_root : dir:string -> string option
