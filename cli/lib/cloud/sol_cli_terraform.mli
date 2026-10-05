val which_check : unit -> bool
val operation_key : chdir:string -> backend_config:string list -> string

val previous_operation
  :  chdir:string
  -> backend_config:string list
  -> Sol_cli_supervised.status

val acknowledge_previous_operation : chdir:string -> backend_config:string list -> unit

type scope

val whole_root : scope
val targets : string -> string list -> scope

val init
  :  ?echo:bool
  -> ?env:(string * string) list
  -> chdir:string
  -> backend_config:string list
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val kv_args : (string * string) list -> string list

val plan
  :  ?env:(string * string) list
  -> scope:scope
  -> chdir:string
  -> var_files:string list
  -> vars:string list
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val plan_refresh_only
  :  ?env:(string * string) list
  -> chdir:string
  -> var_files:string list
  -> vars:string list
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val plan_saved
  :  ?env:(string * string) list
  -> scope:scope
  -> chdir:string
  -> var_files:string list
  -> vars:string list
  -> out:string
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val show_saved_plan
  :  ?env:(string * string) list
  -> run_log:Sol_cli_run_log.t
  -> phase:string
  -> chdir:string
  -> plan_file:string
  -> unit
  -> (string * Sol_cli_terraform_plan.change list, string) result

val apply_saved
  :  ?env:(string * string) list
  -> chdir:string
  -> plan_file:string
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val plan_destroy
  :  ?env:(string * string) list
  -> chdir:string
  -> var_files:string list
  -> vars:string list
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val apply
  :  ?env:(string * string) list
  -> scope:scope
  -> chdir:string
  -> var_files:string list
  -> vars:string list
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val destroy
  :  ?env:(string * string) list
  -> chdir:string
  -> var_files:string list
  -> vars:string list
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val import_
  :  ?env:(string * string) list
  -> chdir:string
  -> var_files:string list
  -> vars:string list
  -> address:string
  -> import_identity:string
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val state_rm
  :  ?env:(string * string) list
  -> chdir:string
  -> address:string
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val output_json
  :  ?env:(string * string) list
  -> chdir:string
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val state_list
  :  ?env:(string * string) list
  -> chdir:string
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val state_addresses
  :  ?env:(string * string) list
  -> chdir:string
  -> unit
  -> (string list, Sol_cli_process.error) result

val show_json
  :  ?env:(string * string) list
  -> chdir:string
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result
