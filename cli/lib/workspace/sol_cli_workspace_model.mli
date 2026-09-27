(** The workspace, read once (REFAC-130).

    Every command that needs to know what a workspace contains reads this once,
    at its edge, and works from the value: a command that asks two questions no
    longer walks the filesystem twice and cannot see two different workspaces.
    The scanners ([Sol_cli_manifest.scan_workspace],
    [Sol_cli_workspace_scan.discover_*], [Sol_cli_config.discover_target_paths])
    are the readers this loader calls; nothing else calls them.

    [root] is the entered workspace root, so the reads are the same whether the
    command was invoked at the root or in a descendant directory. Loading is
    deliberately tolerant of *absence* -- a workspace with no [events/], no
    [db/migrations] or no [app/] simply has no such facts -- and strict about
    *malformed* content, which is an error naming the file. *)

(** One workload: the discovered service, whether it has a Dockerfile, the
    language its [sol.yml] entry declares, and its parsed [sol.toml].

    The [sol.toml] is carried as a [result] rather than failing the load: a
    malformed workload [sol.toml] is what [sol check] exists to report, so the
    loader keeps the finding instead of refusing to build the model. *)
type workload =
  { service : Sol_cli_manifest.service
  ; has_dockerfile : bool
  ; language : Sol_cli_compat.language option
  ; config : (Sol_cli_toml.t, Sol_cli_toml.parse_error) result
  }

(** One migration file, with the facts derived from it: its version and name
    ([Sol_cli_migration.parse_version]) and its authored disposition. The
    disposition is a [result] for the same reason a workload's [sol.toml] is --
    a migration that does not declare one is a rollback-gate finding, not a
    reason the workspace cannot be read. *)
type migration =
  { file : Sol_cli_plan_ids.Migration_file.t
  ; version : int option
  ; name : string option
  ; disposition : (Sol_cli_migration_disposition.t, string) result
  }

type t =
  { root : string
  ; app_dir : string option
    (** [root/app] when the workspace has one. [None] is an infra-first
        workspace with no workloads yet, which [sol check] reports differently
        from an [app/] that exists and is empty. *)
  ; workloads : workload list
  ; unexpected : Sol_cli_manifest.unexpected list
    (** Directories under [app/] that do not name a Sol primitive. *)
  ; topics : Sol_cli_plan_ids.Topic_name.t list
  ; schema_subjects : Sol_cli_plan_ids.Schema_subject.t list
  ; migrations : migration list
  ; targets : string list (** Declared targets, as [<env>/<provider>/<region>]. *)
  }

(** The workspace's services: every workload with a Dockerfile, which is the
    discovery contract every command has used. *)
val services : t -> Sol_cli_manifest.service list

(** The migration files the plan carries, in filename order. *)
val migration_files : t -> Sol_cli_plan_ids.Migration_file.t list

(** The migrations that still have to be applied -- "count unapplied
    migrations". [db/migrations/0001_up.sql] counts; its [0001_up.down.sql]
    companion is the reversal, not a migration of its own. *)
val count_unapplied_migrations : t -> int

(** Read the workspace rooted at [root]. Errors name the file (or the directory)
    that could not be read. *)
val load : root:string -> (t, string) result

(** [load] for the workspace containing the current directory. Commands that
    call {!Sol_cli_workspace.enter_cwd} already have the root and should pass it
    to {!load} instead; this is for the ones that deliberately keep the
    invocation cwd (e.g. [sol deploy]'s relative [--emit-to] paths). *)
val load_cwd : unit -> (t, string) result
