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

(** The previous-release input, three-valued on purpose. [Unreadable] is not
    "there is no previous release": collapsing the two is what dropped the
    protection below (FND-0025). *)
type previous_release =
  | Known of string
  | None_yet
  | Unreadable of string

(** [select ~keep ~current ~previous entries] where [entries] is
    [(release_id, created_at)] in any order and with duplicates allowed.

    Duplicate deploys of one release collapse to its newest appearance — the
    question is "how many distinct releases are recent", not "how many times did
    we deploy". The most recent [keep] distinct releases are retained; [current]
    and every [Known] [previous] are retained even when outside that window.
    Returns the ids to prune, oldest first. Pure.

    [Error] when [previous] is [Unreadable]: a protection input that could not be
    read must never be treated as "nothing to protect", so nothing is pruned and
    the reason is carried for the caller to report. *)
val select
  :  keep:int
  -> current:string
  -> previous:previous_release
  -> (string * string) list
  -> (string list, string) result

(** [prune ~ctx ~workspace ~keep ~current ~previous] lists the workspace's
    releases in the target's cluster, selects the ids to drop, and deletes their
    immutable ConfigMaps. Returns the ids actually pruned, oldest first. Fails
    closed: a listing or deletion error, or an unreadable [previous], is reported
    rather than partially applied. *)
val prune
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> keep:int
  -> current:string
  -> previous:previous_release
  -> (string list, string) result
