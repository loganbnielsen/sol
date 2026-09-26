(** The local infrastructure a workspace needs; decided by
    [Sol_cli_config.local_infra] (REFAC-107). *)
type infra_requirements =
  { kafka : bool
  ; postgres : bool
  ; loki : bool
  ; prometheus : bool
  ; tempo : bool
  }

(** The workspace manifest. A directory containing a [sol.yml] *is* a Sol
    workspace; the file's presence establishes the boundary and its contents
    are optional workspace configuration (DEC-024). *)
val workspace_file : string

type workspace_error =
  | Not_in_workspace
  | Nested_workspace of
      { outer : string
      ; inner : string
      }

(** Human-readable form, for the fail-closed error and the nested-workspace
    error. Both name the fix: creating a workspace, or using siblings. *)
val workspace_error_to_string : workspace_error -> string

(** Walk up from [dir] (inclusive) to the nearest ancestor containing a
    [sol.yml]. Never consults an ecosystem marker ([dune-project],
    [package.json], [.git]) -- language build systems are properties of units,
    not workspace identity (DEC-022 clause 8, DEC-024 clause 5). Returns [None]
    when no ancestor is a Sol workspace. *)
val find_root : dir:string -> string option

(** [find_root] as a result: [Error Not_in_workspace] rather than [None], so
    the absence path can name the fix. *)
val resolve : dir:string -> (string, workspace_error) result

(** Enforce DEC-024's non-nesting invariant: [root] must not contain another
    [sol.yml] below it. Separate from [resolve] so root resolution stays a
    cheap upward walk; discovery and the command boundary call it where the
    invariant has to hold. Reports both boundaries. *)
val validate : root:string -> (unit, workspace_error) result

(** [resolve], then [validate]. *)
val resolve_validated : dir:string -> (string, workspace_error) result

(** [resolve_validated], then [Sys.chdir] to the resolved root. Commands use
    this so relative workspace paths (discovery, [sol.toml], the build
    context) are correct from any descendant directory. *)
val enter : dir:string -> (string, workspace_error) result

(** An entered workspace: its root and its name, so a command learns "where am
    I" from one value (REFAC-111). *)
type t =
  { root : string
  ; name : string (** {!workspace_name} of [root]. *)
  }

(** [enter_or_exit ()] enters the workspace containing the current directory, or
    prints the workspace error and exits 1. The one way a command establishes its
    workspace (REFAC-108): the boundary is validated, absence fails closed, and the
    entered workspace is returned. *)
val enter_or_exit : unit -> t

(** Join a workspace-root-relative path to the resolved root, without changing
    the process cwd. For commands that must keep the invocation cwd (e.g.
    [sol deploy]'s relative [--emit-to]); falls back to the path as given when
    there is no workspace. *)
val at_root : string -> string

(** The workspace name derived from its root, e.g. [pluto] for
    [/src/pluto]. *)
val workspace_name : root:string -> string

(** The workspace name for the current working directory: the basename of the
    resolved workspace root, so a command in a descendant directory names the
    same workspace as one at the root. Falls back to the cwd basename when
    there is no workspace. *)
val current_name : unit -> string

(** Count [.sql] files in [dir/db/migrations]. Returns 0 if the directory does
    not exist. Used by [sol up] to warn users about unapplied migrations. *)
val pending_migration_count : dir:string -> int
