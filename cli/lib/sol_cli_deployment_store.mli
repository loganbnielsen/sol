(** Persist and read deployment-event records through kubectl (FEAT-070).

    One immutable ConfigMap per deployment, [sol-deployment-<deployment_id>], in
    the cluster the target names. The ConfigMap is the authoritative event
    history: [sol deployments] reads it directly and never reconstructs history
    from telemetry. A failure to write is returned to the caller rather than
    raised — a deploy must not claim to have recorded an event it did not.

    There is no pointer object: deployment history is append-only, so the
    newest-first ordering is computed from the records themselves. *)

(** Write one deployment event. *)
val record
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_deployment.t
  -> (unit, string) result

(** All deployment events for [workspace] in the named cluster's [default]
    namespace, unordered. *)
val list
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> (Sol_cli_deployment.t list, string) result
