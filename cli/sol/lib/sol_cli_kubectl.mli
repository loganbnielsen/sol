val apply : file:string -> (unit, Sol_cli_process.error) result
val apply_dry_run : file:string -> (unit, Sol_cli_process.error) result

val get
  :  resource:string
  -> name:string
  -> namespace:string
  -> output:string
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val get_raw : args:string list -> (Sol_cli_process.result, Sol_cli_process.error) result

val logs
  :  pod:string
  -> namespace:string
  -> container:string option
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val rollout_status
  :  kind_name:string
  -> namespace:string
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val rollout_undo
  :  kind_name:string
  -> namespace:string
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val rollout_restart
  :  kind:string
  -> namespace:string
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val patch
  :  resource:string
  -> name:string
  -> namespace:string
  -> patch_type:string
  -> patch:string
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val config_current_context
  :  unit
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val argo_rollout_undo
  :  namespace:string
  -> name:string
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val argo_rollout_status
  :  namespace:string
  -> name:string
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val probe : args:string list -> bool

(** The same probe, but keeping what kubectl said: the exit code and the reason
    a human should see (stderr when present, else stdout). [Error] means kubectl
    could not be run at all, which is a different failure from running and
    failing. Bounded by a timeout, and non-interactive because the runner gives
    children /dev/null on stdin. *)
val probe_result : args:string list -> (int * string, string) result
