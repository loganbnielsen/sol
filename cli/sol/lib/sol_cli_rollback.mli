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

(** Which live Kubernetes kind carries a workload's taxonomy labels, and where
    in that kind's pod template they land. Exposed (rather than kept private) so
    a test can assert this mapping directly, without a cluster: it is pure and
    deterministic, but wrong, it would make every verification report a false
    mismatch, so it needs its own regression coverage. *)
type live_kind =
  | Live_deployment
  | Live_rollout
  | Live_cronjob

(** [live_kind_of_service spec] — [Fn] is always [Live_cronjob] regardless of
    [progressive_delivery]. [Svc]/[Worker] with [progressive_delivery] set are
    [Live_rollout], otherwise [Live_deployment]. *)
val live_kind_of_service : Sol_cli_deployment_plan.service_spec -> live_kind

(** [live_resource_and_jsonpath kind] is the [kubectl get] resource name and the
    jsonpath expression for that kind's `release` label, derived from the single
    pod-template label path also used by {!live_workloads}, so the read side and
    the client-side walk cannot disagree about where the label lives. *)
val live_resource_and_jsonpath : live_kind -> string * string

(** Whether a release may be rolled back directly (FEAT-066). A [Gitops]-owned
    release's resources belong to a controller, so a direct apply + immediate
    readback would report a transition Sol does not control. *)
type apply_mode_check_error = Gitops_owned of { release_id : string }

val apply_mode_check_error_to_string : apply_mode_check_error -> string

(** [check_apply_mode ~release] refuses a {!Sol_cli_release.Gitops} release (whose
    non-identity [apply_mode] is recorded in the release record). *)
val check_apply_mode : release:Sol_cli_release.t -> (unit, apply_mode_check_error) result

(** A workload's live identity: its kind, and the namespace and object name Sol
    derives from the recorded domain/name. Kind matters — a Deployment and a
    Rollout for the same service are different objects, and a release that
    switched between them leaves one behind. *)
type workload_identity =
  { kind : live_kind
  ; namespace : string
  ; name : string
  }

(** [live_workloads ~ctx ~workspace] enumerates the live Sol-owned workloads for
    [workspace] — every Deployment/Rollout/CronJob whose pod template carries the
    [workspace] taxonomy label — as (identity, `release` label) pairs. Fails
    closed: a kind that cannot be enumerated (other than an absent Rollouts CRD)
    is an [Error], never an assumed-empty set. *)
val live_workloads
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> ((workload_identity * string) list, string) result

(** [workload_rows_of_payload ~kind ~workspace payload] extracts those pairs from
    one [kubectl get <kind> -A -o json] payload. Pure, so the wire-path label
    walk is testable without a cluster. [workspace] is the raw workspace name;
    the `workspace` label is matched through
    {!Sol_cli_kubernetes_name.sanitize_label_value}, the same transform the
    renderer applies. *)
val workload_rows_of_payload
  :  kind:live_kind
  -> workspace:string
  -> Yojson.Safe.t
  -> (workload_identity * string) list

(** One workload whose live `release` label does not match the restored release. *)
type workload_mismatch =
  { kind : live_kind
  ; namespace : string
  ; name : string
  ; actual : string
  }

(** The complete live-vs-recorded workload comparison: present-but-wrong labels,
    expected-but-absent objects, and live objects the restored release does not
    contain. Each mode is reported independently and never reconciled. *)
type workload_report =
  { mismatched : workload_mismatch list
  ; missing : workload_identity list
  ; unexpected : (workload_identity * string) list
  }

val workload_report_ok : workload_report -> bool

(** [verify_workloads ~release ~expected ~live] is the pure comparison of the
    restored release's expected workloads against the enumerated live set. *)
val verify_workloads
  :  release:Sol_cli_release.t
  -> expected:Sol_cli_deployment_plan.service_spec list
  -> live:(workload_identity * string) list
  -> workload_report

val workload_report_to_string : release:Sol_cli_release.t -> workload_report -> string

(** The current-release pointer read back after the workload set is verified. *)
type pointer_report =
  { pointer_actual : string
  ; pointer_ok : bool
  }

(** [verify_pointer ~ctx ~release] reads the pointer ConfigMap's [data.release_id]
    and compares it to [release]; it never re-applies or "fixes" a mismatch.
    Reported separately from the workload set so the two failure modes stay
    independent. *)
val verify_pointer
  :  ctx:Sol_cli_kube_destination.context
  -> release:Sol_cli_release.t
  -> pointer_report

val pointer_report_ok : pointer_report -> bool
val pointer_report_to_string : release:Sol_cli_release.t -> pointer_report -> string
