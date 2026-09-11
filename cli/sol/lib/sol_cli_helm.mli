type set_val =
  | Bool of bool
  | Float of float
  | Str of string

val repo_add
  :  name:string
  -> url:string
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val repo_update : unit -> (Sol_cli_process.result, Sol_cli_process.error) result

(** [?values_yaml] is raw YAML content written to a temp file and passed via
    [-f] -- needed for values a flat [--set]/[--set-string] can't express, such
    as Alloy's multi-line River configMap content (OBS-039). The temp file is
    removed after the helm invocation regardless of outcome. [?version] pins the
    chart version, passed as [--version] -- omit to take whatever the repo's
    `helm repo update` currently resolves to as latest. *)
val upgrade_install
  :  release:string
  -> chart:string
  -> namespace:string
  -> ?version:string
  -> ?values:(string * set_val) list
  -> ?values_yaml:string
  -> unit
  -> (Sol_cli_process.result, Sol_cli_process.error) result
