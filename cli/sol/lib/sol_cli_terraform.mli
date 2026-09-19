val which_check : unit -> bool

type scope

val whole_root : scope
val targets : string -> string list -> scope

val init
  :  ?env:(string * string) list
  -> chdir:string
  -> backend_config:string list
  -> unit
  -> (Sol_cli_process.result, Sol_cli_process.error) result

(** ["key=value"] Terraform CLI syntax for a list of neutral key/value pairs —
    e.g. {!Sol_cli_config.terraform_vars}'s result, before it's combined with
    any raw ["key=value"] strings a caller already has (such as [sol cloud]'s
    own [--var] CLI flag) and passed as [~vars] below. *)
val kv_args : (string * string) list -> string list

val plan
  :  ?env:(string * string) list
  -> scope:scope
  -> chdir:string
  -> var_files:string list
  -> vars:string list
  -> unit
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val plan_destroy
  :  ?env:(string * string) list
  -> chdir:string
  -> var_files:string list
  -> vars:string list
  -> unit
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val apply
  :  ?env:(string * string) list
  -> scope:scope
  -> chdir:string
  -> var_files:string list
  -> vars:string list
  -> unit
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val destroy
  :  ?env:(string * string) list
  -> chdir:string
  -> var_files:string list
  -> vars:string list
  -> unit
  -> (Sol_cli_process.result, Sol_cli_process.error) result

(** [terraform state rm <address>] — forget the resource *without* touching the
    object. Only legitimate where the object provably cannot exist: a resource
    whose kind the cluster does not serve has no object to delete, and Terraform
    cannot be asked to delete what has no API (INFRA-042). Anywhere else this would
    be the silent-ignore failure it exists to avoid. *)
val state_rm
  :  ?env:(string * string) list
  -> chdir:string
  -> address:string
  -> unit
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val output_json
  :  ?env:(string * string) list
  -> chdir:string
  -> unit
  -> (Sol_cli_process.result, Sol_cli_process.error) result

(** ["terraform show -json"] — the applied state of every resource, not just
    named outputs. For a destroy-preparation self-check on this root's own
    resources; the named-output contract in {!Sol_cli_cloud_lifecycle} is for
    cross-root wiring and stays the only path for that. *)
val show_json
  :  ?env:(string * string) list
  -> chdir:string
  -> unit
  -> (Sol_cli_process.result, Sol_cli_process.error) result
