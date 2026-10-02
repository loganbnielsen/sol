type workload =
  { service : Sol_cli_manifest.service
  ; has_dockerfile : bool
  ; language : Sol_cli_compat.language option
  ; config : (Sol_cli_toml.t, Sol_cli_toml.parse_error) result
  }

type migration =
  { file : Sol_cli_plan_ids.Migration_file.t
  ; version : int option
  ; name : string option
  ; disposition : (Sol_cli_migration_disposition.t, string) result
  }

type t =
  { root : string
  ; app_dir : string option
  ; workloads : workload list
  ; unexpected : Sol_cli_manifest.unexpected list
  ; topics : Sol_cli_plan_ids.Topic_name.t list
  ; schema_subjects : Sol_cli_plan_ids.Schema_subject.t list
  ; migrations : migration list
  ; targets : string list
  }

val services : t -> Sol_cli_manifest.service list
val workloads : t -> workload list
val migration_files : t -> Sol_cli_plan_ids.Migration_file.t list
val count_unapplied_migrations : t -> int
val load : root:string -> (t, string) result
val load_cwd : unit -> (t, string) result
