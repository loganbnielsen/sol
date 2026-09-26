(** The deployment event (FEAT-070, FEAT-071).

    A release record (FEAT-069) is the authoritative, immutable description of
    *what is running*. A deployment event is the other half: the immutable record
    of *one deploy attempt* — which release it tried to put in place, the
    provenance around the attempt (when, from which commit, by whom, to which
    target), and its [outcome].

    An event is an attempt, not a success: a failed apply is still a deployment
    event, recorded once the attempt finishes with [Apply_failed]. The release
    record is written only when the attempt succeeded — "the release exists"
    is a claim a failed apply cannot make.

    Recording an event is not "this release reached healthy state". Health is
    read from the live workload / Argo and never written back into an immutable
    record. Apply outcome and workload health are different facts.

    The event references a release by [release_id]; it never defines one. Two
    deploys of identical content are two events pointing at one release.

    Storage for self-hosted: one immutable ConfigMap per deployment,
    [sol-deployment-<deployment_id>], labelled for lookup. It is the authority;
    the OBS-037 Loki marker carries the same [deployment_id] only as an
    observability join key, is emitted only after this record has been persisted,
    and [sol deployments] reads the records, never reconstructs history from
    telemetry.

    Both identities stay typed here (FEAT-071): [deployment_id] and [release_id]
    are abstract ids, serialized only at the boundary. *)

(** Whether the attempt put the release in place. *)
type outcome =
  | Applied
  | Apply_failed

type t =
  { deployment_id : Sol_cli_deployment_id.t
  ; release_id : Sol_cli_release_id.t
  ; workspace : string
  ; environment : string option
  ; created_at : string
  ; git_commit : string
  ; git_dirty : bool
  ; actor : string option
  ; target : string option
  ; mode : string
  ; requested_scope : string
  ; profile : Sol_cli_profile.t option
    (** The profile this attempt passed preflight under (FEAT-089). A profile
        is a claim about a target, so it lives on the event that put a release
        on that target, never in the content-addressed release record. *)
  ; outcome : outcome
  }

(** [rfc3339_utc now] is UTC, second precision, lexicographically sortable. The
    event owns this timestamp; it is never reconstructed from the id. *)
val rfc3339_utc : float -> string

(** [of_plan ~deployment_id ~now ~git_commit ~git_dirty ~actor ~target ~outcome
    plan] builds the event for one attempt. The release it points at is
    [plan.release_id] (consumed, never rederived), and [created_at] is [now]. *)
val of_plan
  :  deployment_id:Sol_cli_deployment_id.t
  -> now:float
  -> git_commit:string
  -> git_dirty:bool
  -> actor:string option
  -> target:string option
  -> outcome:outcome
  -> Sol_cli_deployment_plan.t
  -> t

(** Short commit, or [""] when the tree is not a Git checkout. *)
val git_commit : unit -> string

(** Whether the working tree had uncommitted changes. *)
val git_dirty : unit -> bool

val configmap_name : t -> string

(** [validate ~name t] checks the name direction: the object is named
    [sol-deployment-<deployment_id>]. Constructing [t] (through [of_plan] or
    [of_json]) already established both identity types, so there is nothing left
    to re-parse here. *)
val validate : name:string -> t -> (unit, string) result

val to_json : t -> Yojson.Safe.t

(** [of_json] parses both ids at the boundary; a malformed id (or a missing or
    unknown [outcome]) is an error, never a string that reaches a name or a
    label. *)
val of_json : Yojson.Safe.t -> (t, string) result

(** The immutable ConfigMap for one deployment event. *)
val to_configmap_json : t -> string

(** [kubectl get configmap -l ... -o json] -> the events it carries. Fails closed
    (FEAT-071): an item that is absent, unparseable, or does not [validate] is
    corruption and returns an [Error] naming it — the store is authoritative
    history, and dropping a record would print a partial list as if it were the
    whole one. *)
val parse_kubectl_list : Yojson.Safe.t -> (t list, string) result

(** DEPLOYMENT / RELEASE / TIME / COMMIT / STATUS, newest first. *)
val format_table : t list -> string
