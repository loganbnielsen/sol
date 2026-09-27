val migration_files : string -> ((string * string) list, string) result

val registry_of
  :  configured:string option
  -> override:string option
  -> how_to_set:string
  -> (string, string) result

val reconcile_operator_bindings
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> services:Sol_cli_manifest.service list
  -> unit

type verification =
  | No_migrations
  | Satisfied of int list
  | Unsatisfied of Sol_cli_migration.prerequisite list
  | Unavailable of string

val verify
  :  ctx:Sol_cli_kube_destination.context
  -> target:string
  -> workspace:string
  -> dir:string
  -> services:Sol_cli_manifest.service list
  -> verification
