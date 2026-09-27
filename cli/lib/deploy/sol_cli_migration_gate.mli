(** The deploy's migration prerequisite (AUDIT-069), and what it shares with
    [sol migrate apply]'s in-cluster run (REFAC-139).

    Before any workload mutation, a deploy checks that the workspace's required
    migration set is applied in the target cluster, reading [schema_migrations]
    with a short-lived, read-only {!Sol_cli_migration_job}. The check fails
    closed: if it cannot be performed, the answer is {!Unavailable}, never an
    assumption that the schema is compatible. *)

(** [migration_files dir]: the [.sql] files in [dir], sorted, as
    [(file name, contents)]. A file holding a NUL character is refused by name:
    it is carried in a ConfigMap, which YAML cannot give one (REFAC-131). *)
val migration_files : string -> ((string * string) list, string) result

(** [registry_of ~configured ~override ~how_to_set]: the registry the runner
    image is pulled from -- [override] first, then the target's [configured]
    one; with neither, an error that ends in [how_to_set]. *)
val registry_of
  :  configured:string option
  -> override:string option
  -> how_to_set:string
  -> (string, string) result

(** [reconcile_operator_bindings ~ctx ~workspace ~services]: the operator's
    diagnostic RoleBindings across every namespace holding a Sol-managed workload
    (DEC-038 §6). A failure is reported as a warning, never fatal and never
    silent: a read-only grant must not block a deployment. *)
val reconcile_operator_bindings
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> services:Sol_cli_manifest.service list
  -> unit

type verification =
  | No_migrations
  | Satisfied of int list (** the applied versions *)
  | Unsatisfied of Sol_cli_migration.prerequisite list (** what is missing *)
  | Unavailable of string (** the check could not be performed *)

(** [verify ~ctx ~target ~workspace ~dir ~services]. [services] is the
    workspace inventory the deploy already read (REFAC-130). When the check
    Job fails, its evidence is reported and the Job is kept for inspection. *)
val verify
  :  ctx:Sol_cli_kube_destination.context
  -> target:string
  -> workspace:string
  -> dir:string
  -> services:Sol_cli_manifest.service list
  -> verification
