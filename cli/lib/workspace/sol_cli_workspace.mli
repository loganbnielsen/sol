type infra_requirements =
  { kafka : bool
  ; postgres : bool
  ; loki : bool
  ; prometheus : bool
  ; tempo : bool
  }

val workspace_file : string

type workspace_error =
  | Not_in_workspace
  | Nested_workspace of
      { outer : string
      ; inner : string
      }

val workspace_error_to_string : workspace_error -> string
val find_root : dir:string -> string option
val resolve : dir:string -> (string, workspace_error) result
val validate : root:string -> (unit, workspace_error) result
val resolve_validated : dir:string -> (string, workspace_error) result
val enter : dir:string -> (string, workspace_error) result

type t =
  { root : string
  ; name : string
  }

val enter_cwd : unit -> (t, Sol_cli_exit.failure) result
val at_root : string -> string
val workspace_name : root:string -> string
val current_name : unit -> string
val migrations_dir : dir:string -> string
val migrations_table : dir:string -> string
