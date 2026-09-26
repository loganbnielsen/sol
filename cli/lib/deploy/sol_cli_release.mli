(** The release record (DEC-018, FEAT-067; content-addressed by FEAT-069).

    A release record is the authoritative, immutable description of *what is
    running*: the workspace, the environment, and the resolved workloads whose
    difference means "this is a different release". It is named by
    [release_id] and its own content rederives [release_id] through
    {!Sol_cli_release_id.of_content} — so the record a deploy writes, the
    workload's taxonomy [release] label, and the id [sol releases] lists are
    all the same identity, and a GitOps bundle is byte-identical whenever the
    content is.

    Invocation provenance (timestamp, commit, dirty tree, target, actor) is
    deliberately *not* here: it belongs to the deployment event (FEAT-070), and
    putting it in the release artifact would make an identical release produce
    a different diff on every deploy.

    A record never stores secret *values*; it stores the secret references the
    workloads use. Config values are part of the released state and are stored,
    because the record's content is what rederives the id. *)

(** The record's workload is the identity's workload (BUG-026): the record is the
    serialized artifact of the released state, so it does not keep a second,
    hand-mirrored copy of the projection that could drift from the id. *)
type workload = Sol_cli_release_id.workload

(** How a release was applied/owned (FEAT-066): [Direct] when Sol applied the
    manifests itself, [Gitops] when it emitted a bundle a controller owns. This
    is historical per-release truth — a target can switch modes over time, so it
    cannot be inferred from present-day target config. Like {!t.migrations} it is
    excluded from the content-addressed identity (the same desired workload has
    one [release_id] either way) but is protected by {!record_digest}. A rollback
    refuses a [Gitops] release: direct mutation does not establish stable
    controller-owned success. *)
type apply_mode =
  | Direct
  | Gitops

val apply_mode_to_string : apply_mode -> string
val apply_mode_of_string : string -> (apply_mode, string) result

(** Migration filenames known to exist at deploy time (FEAT-066), so a later
    rollback can tell which migrations are new since this release and check
    their disposition. Deliberately excluded from the content-addressed
    identity ({!derived_release_id}): a migration appearing on disk renders no
    manifest, so it must not change [release_id] and force a rollout that
    substantively changed nothing — but it is still recorded in, and
    authoritative from, the body, because "is this the same running state"
    and "what had happened by this point" are different questions. *)
type t =
  { release_id : string
  ; workspace : string
  ; environment : string option
  ; workloads : workload list
  ; migrations : string list
  ; apply_mode : apply_mode
  }

(** Lowercase a value and replace anything a Kubernetes label value forbids, so
    it can be used for lookup. The exact text is preserved in the record body.
    Label *values* may contain [\_], which is why this is not used for names;
    object names go through [Sol_cli_kubernetes_name.sanitize_name]. *)
val sanitize_label : string -> string

val configmap_name : t -> string
val current_configmap_name : workspace:string -> string

(** Build the canonical record from a deployment plan. The id is
    [plan.release_id], consumed rather than recomputed, while the body is the
    resolved content that id is derived from — which is what lets a reader
    validate the record in both directions. [~apply_mode] is recorded as
    non-identity historical metadata (FEAT-066). *)
val of_plan : apply_mode:apply_mode -> Sol_cli_deployment_plan.t -> t

(** [content_of_record t] is the {!Sol_cli_release_id.content} the record
    describes, so a reader can recompute the identity from the stored record
    instead of trusting its name. *)
val content_of_record : t -> Sol_cli_release_id.content

(** [derived_release_id t] recomputes the identity from the record's own
    content. *)
val derived_release_id : t -> Sol_cli_release_id.t

(** [validate ~name t] checks both directions of the step-6 invariant:
    - the name direction: the stored object is called [sol-release-<id>];
    - the content direction: the record's own content rederives [release_id].

    A correctly named record can still be corrupt, stale, or hand-edited, so
    both directions are checked rather than only the cheap one. *)
val validate : name:string -> t -> (unit, string) result

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result

(** The canonical serialized record body — the exact string stored in the
    ConfigMap's [data.record] and in a GitOps bundle, and the representation
    {!record_digest} is defined over. It is canonical: object members are in a
    fixed order and every map/set-like list (workloads, config, secrets, extra
    labels, volumes, calls, migrations) is sorted to a total order, so it is a
    function of the record and not of the order a caller built it in. Its
    stability is pinned by a known vector in the release tests. *)
val record_json_string : t -> string

(** [record_digest t] is the free integrity digest of the complete record body,
    stored alongside it as [data.record_digest] and rechecked on read. It makes
    every persisted field tamper-evident, including the non-identity fields
    ([migrations], [apply_mode]) that [release_id] cannot protect. It is an
    integrity check, not a signature: it detects corruption and inconsistent
    writes, not an actor who can rewrite the whole ConfigMap.

    The read side hashes the stored bytes rather than re-deriving them, so a
    record stays verifiable however the canonical encoder or the JSON serializer
    evolves later. It is deliberately not defined over
    {!Sol_cli_release_id.canonical_string}, whose encoding is a versioned
    identity contract that may change. *)
val record_digest : t -> string

(** [(filename, contents)] for the release artifacts a GitOps bundle carries:
    the immutable [sol-release-<id>.yaml] record and the mutable
    [sol-current-release.yaml] pointer. A pure function of [t], so identical
    content produces byte-identical files. *)
val bundle_files : t -> (string * string) list

(** The immutable per-release ConfigMap, as JSON (kubectl accepts JSON). *)
val to_configmap_json : t -> string

(** The mutable pointer ConfigMap naming the current release for a workspace.
    Its payload is [release_id] only: the record is the one authoritative
    description, and the pointer is a claim about which one is selected. *)
val to_current_configmap_json : t -> string

(** Parse a single release ConfigMap object, as returned by
    [kubectl get configmap <name> -o json] or one entry of a list's [items].
    Fails closed (FEAT-071): a record that is missing, malformed, or fails
    {!validate} is corruption and returns an [Error] naming it. FEAT-066 also
    checks {!record_digest} here first: a body without a digest is an
    unsupported record format, and a body whose digest does not match is
    corruption — so the non-identity safety fields are as tamper-evident as the
    id. Shared by {!parse_kubectl_list} and a single-release lookup (FEAT-066). *)
val of_kubectl_item : Yojson.Safe.t -> (t, string) result

(** Parse [kubectl get configmap -l … -o json]. Fails closed (FEAT-071): a
    matching record that is missing, malformed, or fails {!validate} is
    corruption and returns an [Error] naming it, rather than a short list that
    reads as the whole history. *)
val parse_kubectl_list : Yojson.Safe.t -> (t list, string) result

(** The same parse, pairing each record with its cluster-assigned
    [metadata.creationTimestamp]. The record itself deliberately carries no
    timestamp (FEAT-069), so FEAT-072 retention orders by this instead; it is
    object metadata and never enters [t], [to_json] or {!record_digest}. *)
val parse_kubectl_list_with_creation : Yojson.Safe.t -> ((t * string) list, string) result

(** An aligned [ID / ENV / WORKLOADS] table, ordered by id. *)
val format_table : t list -> string

(** DEC-037: a deployment's outcome, given how recording the release went.

    [record_release] writes the authoritative release state; [report_success]
    prints the deploy's success output. A record failure is returned and
    [report_success] is **not** called — the workloads may be running, but the
    deployment has not succeeded, and it must not say that it has.

    Both `sol deploy` and `sol up` route through this so the order and the
    propagation cannot drift between them. *)
val finish_deployment
  :  record_release:(unit -> (unit, string) result)
  -> report_success:(unit -> unit)
  -> (unit, string) result
