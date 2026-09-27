type outcome =
  | Exited of int
  | Signaled of int

type status =
  | No_previous
  | Running of
      { pid : int
      ; host : string
      ; started_at : float
      ; dir : string
      }
  | Resolved of
      { outcome : outcome
      ; dir : string
      }
  | Unresolved of
      { reason : string
      ; dir : string
      }

type facts =
  { recorded_outcome : outcome option
  ; same_host : bool
  ; alive : bool
  ; errored_state : string option
  ; acknowledged : bool
  ; pid : int
  ; host : string
  ; started_at : float
  ; dir : string
  }

val classify : facts -> status
val status_to_string : status -> string
val operations_dir : key:string -> string
val latest : key:string -> status
val acknowledge : key:string -> unit

val run
  :  ?echo:bool
  -> ?supervisor:string
  -> key:string
  -> root:string
  -> Sol_cli_process.cmd
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val dispatch_if_supervisor : unit -> unit
