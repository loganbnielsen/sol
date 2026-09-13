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

(** [record_plan ~ctx plan] builds the canonical record from a deployment plan
    — its id is [plan.release_id] — and writes it. This is the entry point both
    [sol up] and [sol deploy] use. *)
val record_plan
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_deployment_plan.t
  -> (unit, string) result

(** All release records for [workspace] in the named cluster's [default]
    namespace, unordered. *)
val list
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> (Sol_cli_release.t list, string) result
