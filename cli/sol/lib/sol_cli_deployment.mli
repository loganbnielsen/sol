(** The deployment event (FEAT-070).

    A release record (FEAT-069) is the authoritative, immutable description of
    *what is running*. A deployment event is the other half: the immutable record
    of *one deploy invocation* — which release it attempted, and the provenance
    around the attempt (when, from which commit, by whom, to which target).

    Recording an event is not "this release reached healthy state". Health is
    read from the live workload / Argo and never written back into an immutable
    record; an event records that the attempt happened and what it applied.

    The event references a release by [release_id]; it never defines one. Two
    deploys of identical content are two events pointing at one release.

    Storage for self-hosted: one immutable ConfigMap per deployment,
    [sol-deployment-<deployment_id>], labelled for lookup. It is the authority;
    the OBS-037 Loki marker carries the same [deployment_id] only as an
    observability join key, and [sol deployments] reads the records, never
    reconstructs history from telemetry. *)

type t =
  { deployment_id : string
  ; release_id : string
  ; workspace : string
  ; environment : string option
  ; created_at : string
  ; git_commit : string
  ; git_dirty : bool
  ; actor : string option
  ; target : string option
  ; mode : string
  ; requested_scope : string
  }

(** [rfc3339_utc now] is UTC, second precision, lexicographically sortable. The
    event owns this timestamp; it is never reconstructed from the id. *)
val rfc3339_utc : float -> string

(** [of_plan ~deployment_id ~now ~git_commit ~git_dirty ~actor ~target plan]
    builds the event for one invocation. The release it points at is
    [plan.release_id] (consumed, never rederived), and [created_at] is [now]. *)
val of_plan
  :  deployment_id:Sol_cli_deployment_id.t
  -> now:float
  -> git_commit:string
  -> git_dirty:bool
  -> actor:string option
  -> target:string option
  -> Sol_cli_deployment_plan.t
  -> t

(** Short commit, or [""] when the tree is not a Git checkout. *)
val git_commit : unit -> string

(** Whether the working tree had uncommitted changes. *)
val git_dirty : unit -> bool

val configmap_name : t -> string

(** [validate ~name t] checks both directions: the object is named
    [sol-deployment-<deployment_id>], the id itself parses, and [release_id]
    parses as a release id — a correctly named event that points at a corrupt
    release is still corrupt. *)
val validate : name:string -> t -> (unit, string) result

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result

(** The immutable ConfigMap for one deployment event. *)
val to_configmap_json : t -> string

(** [kubectl get configmap -l ... -o json] -> the events it carries. Items that
    are absent, malformed, or do not [validate] are skipped rather than failing
    the listing. *)
val parse_kubectl_list : Yojson.Safe.t -> (t list, string) result

(** DEPLOYMENT / RELEASE / TIME / COMMIT, newest first. *)
val format_table : t list -> string
