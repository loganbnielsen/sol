type rollback_target =
  | Standard_deployment of
      { namespace : string
      ; name : string
      }
  | Argo_rollout of
      { namespace : string
      ; name : string
      }
  | No_op of string

type error =
  | Kubectl_error of Sol_cli_process.error
  | Plugin_missing of
      { namespace : string
      ; name : string
      }
  | Non_zero of
      { command : string
      ; exit_code : int
      }

(** Derive a [rollback_target] from a resolved service spec. [Fn] primitives
    produce [No_op] because CronJobs do not support rollout history. Services
    with [progressive_delivery] set produce [Argo_rollout]. All others produce
    [Standard_deployment]. *)
val rollback_target_of_service : Sol_cli_deployment_plan.service_spec -> rollback_target

(** Return [true] when the kubectl-argo-rollouts plugin is reachable via
    [kubectl-argo-rollouts version] or [kubectl argo rollouts version]. *)
val argo_plugin_available : ctx:Sol_cli_kube_destination.context -> unit -> bool

(** Execute the rollback for the given target in the cluster [ctx] names.
    [Standard_deployment] calls [kubectl rollout undo] then [kubectl rollout
    status]. [Argo_rollout] calls [kubectl argo rollouts undo] if the plugin is
    available, or returns [Error (Plugin_missing _)] otherwise. [No_op] always
    returns [Ok ()]. *)
val execute_rollback
  :  ctx:Sol_cli_kube_destination.context
  -> rollback_target
  -> (unit, error) result

val error_to_string : error -> string

(** [service_specs_of_release release] reconstructs the resolved
    [service_spec] list a deploy of [release] would have produced (FEAT-066).

    This is a historical decode, not a planner: it depends exclusively on data
    reachable from [release] plus pure deterministic helpers ([k8s_name_result],
    [namespace_result], [service_url], [call_env_var], and the canonical
    inverse decoders in {!Sol_cli_toml}) — never the workspace, [sol.toml]/
    [sol.yml], the current environment, discovery, or current cluster state.

    [called_by] is not a field of the stored record; it is derived purely from
    every workload's own [calls] rows (matching by target namespace/name), using
    the same [call_env_var] helper the forward planner uses. Reusing a stored
    forward-edge env var here would preserve most of the call graph while
    silently changing NetworkPolicy output.

    Decode failures name the release, the workload and the offending fact —
    e.g. ["cannot reconstruct release r-x: workload payments has an invalid
    progressive delivery \"canary:bogus\""] — before any render or mutation, so
    a corrupt historical artifact is distinguishable from a cluster refusing a
    valid restoration. *)
val service_specs_of_release
  :  Sol_cli_release.t
  -> (Sol_cli_deployment_plan.service_spec list, string) result

(** DEC-018's migration boundary check. Unlike {!service_specs_of_release},
    this legitimately reads ambient state — comparing the target release's
    recorded migration set against what exists now is, by definition, not
    something the release record alone can answer. *)
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

(** [check_migration_boundary ~release ~migrations_dir ~current_migrations]
    refuses only on a migration that is both new since [release] (present in
    [current_migrations] but not [release.migrations]) and either declares a
    [Contract] disposition, or fails to declare one at all (missing/malformed
    header) — there is no "assume expand" fallback for an undeclared
    migration, because that would silently accept the exact risk this check
    exists to catch. An [Expand] migration never blocks. [migrations_dir] and
    [current_migrations] are caller-supplied (rather than discovered here) so
    the check stays testable and the caller controls where "now" comes
    from. *)
val check_migration_boundary
  :  release:Sol_cli_release.t
  -> migrations_dir:string
  -> current_migrations:string list
  -> (unit, migration_check_error) result

(** One workload whose live [release] label does not match the restored
    release. [actual] is [""] when the label or the object itself could not
    be read at all (never distinguished from an empty label — both mean
    "not verified"). *)
type workload_mismatch =
  { namespace : string
  ; name : string
  ; actual : string
  }

(** The result of the last enforcement-order step: reading back live cluster
    state after [apply] and the pointer move, so the two failure modes stay
    independent — a workload mismatch with a correct pointer is a different
    operational fact than a pointer mismatch with correct workloads. *)
type verify_report =
  { workload_mismatches : workload_mismatch list
  ; pointer_actual : string
  ; pointer_ok : bool
  }

val verify_ok : verify_report -> bool

(** [verify ~ctx ~release specs] reads back, for every [spec], the live
    `release` label Sol renders into that workload's pod template (a
    Deployment or Rollout's [spec.template...], a CronJob's
    [spec.jobTemplate.spec.template...]) and compares it to
    [release.release_id]; and reads back the current-release pointer
    ConfigMap's [data.release_id]. Never re-applies or "fixes" a mismatch —
    only reports it. *)
val verify
  :  ctx:Sol_cli_kube_destination.context
  -> release:Sol_cli_release.t
  -> Sol_cli_deployment_plan.service_spec list
  -> verify_report

val verify_report_to_string : release:Sol_cli_release.t -> verify_report -> string
