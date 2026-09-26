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

(** [unexpected_workloads ~expected ~live] is the live Sol-owned workloads
    that are not part of [expected] -- the pure surplus computation
    {!verify_workloads} uses internally, exposed directly (FEAT-074) so
    [sol deploy]/[sol up] can report drift without a full release-comparison
    report, which needs a recorded release {!verify_workloads} has and a
    forward deploy doesn't. *)
val unexpected_workloads
  :  expected:Sol_cli_deployment_plan.service_spec list
  -> live:(workload_identity * string) list
  -> (workload_identity * string) list

(** [verify_workloads ~release ~expected ~live] is the pure comparison of the
    restored release's expected workloads against the enumerated live set. *)
val verify_workloads
  :  release:Sol_cli_release.t
  -> expected:Sol_cli_deployment_plan.service_spec list
  -> live:(workload_identity * string) list
  -> workload_report

val workload_report_to_string : release:Sol_cli_release.t -> workload_report -> string

(** The [kubectl]/human-readable resource name for a {!live_kind}
    ("deployment", "rollout", "cronjob"). *)
val kind_resource : live_kind -> string

(** [prune_workloads ~ctx surplus] deletes each surplus workload's live
    object (FEAT-074) -- the primary Deployment/Rollout/CronJob only; see the
    [.ml] comment on why associated ConfigMap/Secret/PVC/Service/Ingress/
    NetworkPolicy/ServiceAccount objects are deliberately left alone. Attempts
    every deletion even if one fails, so one failure does not leave unrelated
    surplus objects behind; aggregates any failures into one error naming
    each. *)
val prune_workloads
  :  ctx:Sol_cli_kube_destination.context
  -> (workload_identity * string) list
  -> (unit, string) result

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

(** FEAT-075: the cluster-touching/mutating steps of a rollback, injectable so
    [execute]'s order is testable without a cluster. [apply] renders and
    applies the reconstructed workloads; [live_workloads] enumerates the live
    set for verification; [prune] (FEAT-074) deletes a purely-[unexpected]
    surplus; [move_pointer] and [verify_pointer] are the current-release
    pointer's write and readback. *)
type transaction_deps =
  { apply : Sol_cli_deployment_plan.service_spec list -> (unit, string) result
  ; live_workloads : unit -> ((workload_identity * string) list, string) result
  ; prune : (workload_identity * string) list -> (unit, string) result
  ; move_pointer : unit -> (unit, string) result
  ; verify_pointer : unit -> pointer_report
  }

(** [execute ~release ~migrations_dir ~current_migrations ~deps] is FEAT-066's
    load-bearing rollback ordering: apply-mode refusal, then migration
    boundary refusal, then reconstruction, then [deps.apply], then
    [deps.live_workloads] compared against the reconstructed set. A
    mismatched or missing workload refuses outright — neither is fixable by
    deleting something. Otherwise (FEAT-074) [deps.prune] is called with
    whatever [unexpected] surplus the comparison found (possibly none), and
    only once that succeeds do [deps.move_pointer] and [deps.verify_pointer]
    run. Every check before [deps.apply] only reads; [deps.move_pointer] is
    never called when the workload-set verification disagrees or pruning
    fails. A caller gets this ordering by construction, not by convention —
    it cannot call [deps.move_pointer] before [deps.apply] without bypassing
    [execute] entirely. *)
val execute
  :  release:Sol_cli_release.t
  -> migrations_dir:string
  -> current_migrations:string list
  -> deps:transaction_deps
  -> (unit, string) result

(** FEAT-073: [sol rollback --commit] resolution, against FEAT-070's
    deployment-event record (never Loki, which is telemetry, not an
    authoritative store). *)

(** Exposed for testing: whether a user-supplied commit and a stored
    [git_commit] name the same commit. Case-insensitive, either direction (a
    full sha resolving a stored short sha, or vice versa); empty on either
    side never matches. *)
val commit_matches : commit:string -> string -> bool

type commit_resolution =
  | Commit_invalid of string
  | Commit_no_match
  | Commit_ambiguous of (string * string) list (** (release_id, requested_scope) *)
  | Commit_resolved of string (** release_id *)

(** [resolve_commit ~commit ?scope ~target events] resolves [commit] to the
    release id a successful (["Applied"]) deploy of it produced on [target],
    optionally narrowed by [scope] (["DOMAIN"] or ["DOMAIN/UNIT"], matched
    against the deployment event's recorded [requested_scope] exactly — never
    "restore part of a release"; a release's workload list always restores
    whole). More than one distinct release id matching is [Commit_ambiguous],
    never guessed. *)
val resolve_commit
  :  commit:string
  -> ?scope:string
  -> target:string
  -> Sol_cli_deployment.t list
  -> commit_resolution

(** Human-readable rendering of a {!commit_resolution}, for the CLI's error
    and confirmation output. *)
val commit_resolution_to_string
  :  commit:string
  -> target:string
  -> ?scope:string
  -> commit_resolution
  -> string
