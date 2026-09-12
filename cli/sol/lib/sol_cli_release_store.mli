(** Persist and read release records through kubectl (FEAT-067).

    The write path is two applies: the immutable per-release ConfigMap, then the
    mutable pointer naming the current release. A failure to write is returned
    to the caller rather than raised — a deploy must not claim to have recorded
    a release it did not. *)

(** Write the release record and update the workspace's current-release
    pointer. *)
val record : Sol_cli_release.t -> (unit, string) result

(** [record_plan ~workspace ~target ~mode plan] builds the record from a
    deployment plan (reading git provenance itself) and writes it. This is the
    entry point both [sol up] and [sol deploy] use. *)
val record_plan
  :  workspace:string
  -> target:string
  -> mode:string
  -> Sol_cli_deployment_plan.t
  -> (unit, string) result

(** All release records for [workspace] in the current cluster's [default]
    namespace, unordered. *)
val list : workspace:string -> (Sol_cli_release.t list, string) result
