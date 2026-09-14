(** FEAT-072 / DEC-018: bounded, count-based release-history retention.

    DEC-018 keeps "the last 20 successful releases per target, with current and
    previous never pruned". Two properties of the release model make this
    simpler than it sounds:

    - A release record is written only when an apply succeeded
      ([cmd_up.ml]/[cmd_deploy.ml]), so the release store *is* the
      successful-release history. There is no failure filter to apply — the
      "successful only" rule is structural, not conditional.
    - The record itself deliberately carries no timestamp (FEAT-069), so order
      comes from each record's cluster-assigned [metadata.creationTimestamp].

    This module never touches the current-release pointer, and the caller passes
    in both "current" and "previous" explicitly: only the transition that is
    happening knows which release it displaced, so retention is run at the
    transition (a successful deploy/up), not as an ambient sweep. *)

(** DEC-018's default window. *)
val default_keep : int

(** [select ~keep ~current ~previous entries] where [entries] is
    [(release_id, created_at)] in any order and with duplicates allowed.

    Duplicate deploys of one release collapse to its newest appearance — the
    question is "how many distinct releases are recent", not "how many times did
    we deploy". The most recent [keep] distinct releases are retained; [current]
    and [previous] are always retained even when outside that window. Returns the
    ids to prune, oldest first. Pure. *)
val select
  :  keep:int
  -> current:string
  -> previous:string option
  -> (string * string) list
  -> string list

(** [prune ~ctx ~workspace ~keep ~current ~previous] lists the workspace's
    releases in the target's cluster, selects the ids to drop, and deletes their
    immutable ConfigMaps. Returns the ids actually pruned, oldest first. Fails
    closed: a listing or deletion error is reported rather than partially
    applied. *)
val prune
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> keep:int
  -> current:string
  -> previous:string option
  -> (string list, string) result
