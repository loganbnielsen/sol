val service_specs_of_release
  :  Sol_cli_release.t
  -> (Sol_cli_deployment_plan.service_spec list, string) result

type migration_check_error =
  | Contracting_migration of
      { release_id : string
      ; migration : string
      }
  | Undeclared_disposition of
      { release_id : string
      ; migration : string
      ; reason : string
      }

val migration_check_error_to_string : migration_check_error -> string

val check_migration_boundary
  :  release:Sol_cli_release.t
  -> migrations_dir:string
  -> current_migrations:string list
  -> (unit, migration_check_error) result

type live_kind =
  | Live_deployment
  | Live_rollout
  | Live_cronjob

val live_kind_of_service : Sol_cli_deployment_plan.service_spec -> live_kind
val live_resource_and_jsonpath : live_kind -> string * string

type apply_mode_check_error = Gitops_owned of { release_id : string }

val apply_mode_check_error_to_string : apply_mode_check_error -> string
val check_apply_mode : release:Sol_cli_release.t -> (unit, apply_mode_check_error) result

type workload_identity =
  { kind : live_kind
  ; namespace : string
  ; name : string
  }

val live_workloads
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> ((workload_identity * string) list, string) result

val workload_rows_of_payload
  :  kind:live_kind
  -> workspace:string
  -> Yojson.Safe.t
  -> ((workload_identity * string) list, string) result

type workload_mismatch =
  { kind : live_kind
  ; namespace : string
  ; name : string
  ; actual : string
  }

type workload_report =
  { mismatched : workload_mismatch list
  ; missing : workload_identity list
  ; unexpected : (workload_identity * string) list
  }

val workload_report_ok : workload_report -> bool

val unexpected_workloads
  :  expected:Sol_cli_deployment_plan.service_spec list
  -> live:(workload_identity * string) list
  -> (workload_identity * string) list

val verify_workloads
  :  release:Sol_cli_release.t
  -> expected:Sol_cli_deployment_plan.service_spec list
  -> live:(workload_identity * string) list
  -> workload_report

val workload_report_to_string : release:Sol_cli_release.t -> workload_report -> string
val kind_resource : live_kind -> string

val prune_workloads
  :  ctx:Sol_cli_kube_destination.context
  -> (workload_identity * string) list
  -> (unit, string) result

type pointer_report =
  { pointer_actual : string
  ; pointer_ok : bool
  }

val verify_pointer
  :  ctx:Sol_cli_kube_destination.context
  -> release:Sol_cli_release.t
  -> pointer_report

val pointer_report_ok : pointer_report -> bool
val pointer_report_to_string : release:Sol_cli_release.t -> pointer_report -> string

type transaction_deps =
  { ensure_held : unit -> (unit, string) result
  ; apply : Sol_cli_deployment_plan.service_spec list -> (unit, string) result
  ; live_workloads : unit -> ((workload_identity * string) list, string) result
  ; prune : (workload_identity * string) list -> (unit, string) result
  ; move_pointer : unit -> (unit, string) result
  ; verify_pointer : unit -> pointer_report
  }

val execute
  :  release:Sol_cli_release.t
  -> migrations_dir:string
  -> current_migrations:string list
  -> deps:transaction_deps
  -> (unit, string) result

val commit_matches : commit:string -> string -> bool

type commit_resolution =
  | Commit_invalid of string
  | Commit_no_match
  | Commit_ambiguous of (string * string) list
  | Commit_resolved of string

val resolve_commit
  :  commit:string
  -> ?scope:string
  -> target:string
  -> Sol_cli_deployment.t list
  -> commit_resolution

val commit_resolution_to_string
  :  commit:string
  -> target:string
  -> ?scope:string
  -> commit_resolution
  -> string
