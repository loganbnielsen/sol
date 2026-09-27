val base_dir : string
val generate_run_id : prefix:string -> now:float -> pid:int -> string
val tail_lines : n:int -> string -> string
val phase_log_content : stdout:string -> stderr:string -> string
val format_phase_line : name:string -> elapsed_s:float -> ok:bool -> string
val format_failure_report : run_id:string -> log_path:string -> tail:string -> string
val run_is_live : string -> bool

val runs_to_prune
  :  ?exclude:string list
  -> all_run_ids:string list
  -> keep:int
  -> unit
  -> string list

type t

val create : ?base:string -> ?keep:int -> prefix:string -> unit -> t
val run_id : t -> string
val dir : t -> string
val phase_log_path : t -> phase:string -> string
val append_phase_log : t -> phase:string -> string -> unit

val run_phase
  :  t
  -> name:string
  -> (unit -> (Sol_cli_process.output, Sol_cli_process.error) result)
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val run_task : t -> name:string -> (unit -> ('a, string) result) -> ('a, string) result
