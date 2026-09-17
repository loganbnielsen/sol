(* HARDEN-002 (run 1): the database master password a provider root needs when it
   provisions Postgres. Pure policy — the caller supplies the terraform variables
   it would pass and the environment value it would inherit. *)

(** Where the password a provider-root apply would use comes from. *)
type source =
  | Not_needed (** this invocation does not create Postgres *)
  | Environment (** [TF_VAR_db_password] carries it *)
  | Command_line (** passed with [--var]; always refused *)
  | Missing

val source
  :  provider:Sol_cli_provider.t
  -> vars:string list
  -> tf_var_env:string option
  -> source

(** [check ~provider ~vars ~tf_var_env] is [Ok ()] when the invocation may
    proceed, and [Error reason] — naming the fix and the leak it avoids — when
    Postgres would be created with no credential source, or with one passed in
    the argument vector. Never inspects or carries a password value itself. *)
val check
  :  provider:Sol_cli_provider.t
  -> vars:string list
  -> tf_var_env:string option
  -> (unit, string) result
