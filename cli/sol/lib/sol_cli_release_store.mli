(** Persist and read release records through kubectl (FEAT-067).

    The write path is two applies: the immutable per-release ConfigMap, then the
    mutable pointer naming the current release. A failure to write is returned
    to the caller rather than raised — a deploy must not claim to have recorded
    a release it did not.

    FEAT-063: records are written to the cluster the target names, so every entry
    point takes the destination-side context. *)

(** Write the release record and update the workspace's current-release
    pointer. *)
val record
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_release.t
  -> (unit, string) result

(** [record_plan ~ctx ~apply_mode plan] builds the canonical record from a
    deployment plan — its id is [plan.release_id] — and writes it. This is the
    entry point both [sol up] and [sol deploy] use. [~apply_mode] (FEAT-066)
    records how this release is owned ([Direct] for a Sol apply, [Gitops] for an
    emitted bundle), as non-identity historical metadata a rollback can refuse
    on. *)
val record_plan
  :  ctx:Sol_cli_kube_destination.context
  -> apply_mode:Sol_cli_release.apply_mode
  -> Sol_cli_deployment_plan.t
  -> (unit, string) result

(** All release records for [workspace] in the named cluster's [default]
    namespace, unordered. *)
val list
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> (Sol_cli_release.t list, string) result

(** The same records, each paired with its cluster [metadata.creationTimestamp],
    which FEAT-072 retention orders by (the record itself has no timestamp). *)
val list_with_creation
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> ((Sol_cli_release.t * string) list, string) result

(** [get ~ctx ~workspace ~release_id] loads and validates a single release
    record by id (FEAT-066's rollback resolve step). Fails closed: an
    unparseable [release_id], a missing ConfigMap, a corrupt record, or a
    record whose own [workspace] does not match the one requested (a defense
    against restoring the wrong workspace's release) are all [Error], never a
    default or a best-effort partial record. *)
val get
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> release_id:string
  -> (Sol_cli_release.t, string) result

(** The pointer's [data.release_id] without loading the record; [None] when no
    pointer exists yet. FEAT-072 retention uses this to protect the release that
    was current before a transition. *)
val current
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> (string option, string) result

(** Delete one immutable release record by id (FEAT-072 retention). Never touches
    the pointer, and a malformed id is an [Error] before it becomes a name. *)
val delete
  :  ctx:Sol_cli_kube_destination.context
  -> release_id:string
  -> (unit, string) result

(** Write only the mutable current-release pointer for [t.workspace] to name
    [t.release_id] — unlike {!record}, does not (re-)apply the immutable
    per-release ConfigMap, which for a rollback already exists (it is the
    record being restored from). Used by rollback's pointer-move step, kept
    separate from the apply of the restored workloads' manifests so the two
    can be sequenced with verification in between (FEAT-066). *)
val move_pointer
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_release.t
  -> (unit, string) result
