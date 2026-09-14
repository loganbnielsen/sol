(** FEAT-072: the per-boundary mutation lease, shared by deploy and rollback.

    DEC-018's rule for an in-flight deploy is "abort, establish quiescence, then
    restore" — one verb, because a user who asked for a rollback does not mean
    "cancel, then decide". A lease is the coordination object that makes that
    possible without two processes mutating the same boundary: [sol deploy] and
    [sol up] hold it while applying, and [sol rollback] must acquire the same
    lease before it changes anything.

    The boundary is the workspace. It is the unit the current-release pointer and
    the release history are scoped to, and a rollback restores a release whole,
    so there is no narrower boundary a mutation could safely use.

    Storage is one mutable ConfigMap per workspace in the target's [default]
    namespace, [sol-boundary-lease-<workspace>]. It is deliberately *not*
    [immutable] (unlike a release record): the heartbeat and the abort flag are
    writes. Acquisition is [kubectl create] — the API server is the arbiter, so
    two processes cannot both believe they created it. A holder whose heartbeat
    is older than [ttl] is treated as crashed and may be taken over with a
    [resourceVersion] compare-and-swap; a *live* holder is never stolen. *)

(** Who holds the boundary. Only a [Deploy] may be asked to abort: two rollbacks
    racing each other means something is already wrong, and fighting over the
    boundary would only make it worse. *)
type holder =
  | Deploy
  | Rollback

val holder_to_string : holder -> string
val holder_of_string : string -> (holder, string) result

type t =
  { boundary : string (** Raw workspace name (not the sanitized object name). *)
  ; holder : holder
  ; run_id : string
    (** Unique per operation, so a take-over can tell "the same deploy" from "a
        different process that reused the boundary". *)
  ; started_at : float (** Epoch seconds. *)
  ; heartbeat_at : float (** Epoch seconds; refreshed before each apply. *)
  ; abort_requested : bool
  ; abort_reason : string option
  }

(** A holder that has not refreshed for this long is treated as crashed. *)
val default_ttl_s : float

(** How long a rollback waits for a live deploy to acknowledge an abort before
    refusing to race it. *)
val rollback_wait_s : float

val configmap_name : workspace:string -> string
val make_run_id : holder:holder -> now:float -> pid:int -> string
val create : boundary:string -> holder:holder -> run_id:string -> now:float -> t
val with_heartbeat : t -> now:float -> t
val with_abort_requested : t -> reason:string -> t
val is_stale : now:float -> ttl:float -> t -> bool

(** Human-readable holder description for refusal and progress messages. *)
val describe : t -> string

(** What a fresh acquirer should do given what is currently on the boundary. *)
type decision =
  | Proceed (** Free, stale, or already ours: take it. *)
  | Request_abort of string (** A live deploy holds it; ask it to stop, then wait. *)
  | Refuse of string (** A live holder that must not or cannot be displaced. *)

(** [deploy_decision ~now ~ttl current]: deploy never aborts another operation
    and never steals a live lease — a second deploy refuses and tells the
    operator who holds the boundary. *)
val deploy_decision : now:float -> ttl:float -> t option -> decision

(** [rollback_decision ~now ~ttl current]: rollback aborts a live deploy and
    waits, but refuses a live rollback. A stale holder of either kind is taken
    over. *)
val rollback_decision : now:float -> ttl:float -> t option -> decision

val to_configmap_json : t -> string

(** Parse one ConfigMap object, returning the lease and its [resourceVersion]. *)
val of_configmap_item : Yojson.Safe.t -> (t * string, string) result

(** How a write failed. [Already_exists] and [Conflict] are the control-flow
    outcomes of the optimistic acquire, not errors to show a user. *)
type write_error =
  | Already_exists
  | Conflict (** The [resourceVersion] precondition failed. *)
  | Other of string

val create_object
  :  ctx:Sol_cli_kube_destination.context
  -> t
  -> (unit, write_error) result

val replace_object
  :  ctx:Sol_cli_kube_destination.context
  -> t
  -> resource_version:string
  -> (unit, write_error) result

(** [None] means the boundary is free (the ConfigMap is absent); any other
    failure is an [Error], never an assumed-free boundary. *)
val fetch
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> ((t * string) option, string) result

val remove
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> (unit, string) result

(** A lease this process owns, together with the context and run id needed to
    refresh and release it. Opaque on purpose: the caller treats the lease as a
    resource, not as fields to keep in step. *)
type held

(** [acquire ~ctx ~workspace ~holder ~ttl ~wait_s] takes the lease, minting a
    unique run id.

    A [Deploy] with [wait_s = 0.] acquires a free/stale lease and refuses a live
    one. A [Rollback] requests an abort from a live deploy, prints the request,
    and polls until the lease is free/stale or [wait_s] elapses; if it times
    out, it refuses and names the holder. *)
val acquire
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> holder:holder
  -> ttl:float
  -> wait_s:float
  -> (held, string) result

(** The result of refreshing a held lease. *)
type heartbeat_result =
  | Held
  | Aborted of string (** A rollback asked this deploy to stop. *)

(** [heartbeat h] refreshes [h]. [Error] means the lease was stolen or
    disappeared, which the caller must treat as "stop mutating": it no longer
    owns the boundary. *)
val heartbeat : held -> (heartbeat_result, string) result

(** [ensure_held h] is [Ok ()] while the lease is still this process's and no
    abort was requested, and an [Error] explaining why otherwise — the shape a
    caller wants between one mutation and the next. *)
val ensure_held : held -> (unit, string) result

(** Release a lease this process still holds; refuses to delete a lease that was
    taken over by someone else. *)
val release : held -> (unit, string) result

(** [release_with_warning h] releases, printing a warning rather than raising or
    exiting on failure. *)
val release_with_warning : held -> unit

(** [with_boundary_lease ~ctx ~workspace ~holder ~ttl ~wait_s f] acquires the
    lease, runs [f], and releases it however [f] returns. [f] returns a result
    (never [exit]) so the lease is released exactly once, with no [at_exit]
    hook to compensate. *)
val with_boundary_lease
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> holder:holder
  -> ttl:float
  -> wait_s:float
  -> (held -> ('a, string) result)
  -> ('a, string) result
