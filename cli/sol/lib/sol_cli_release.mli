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

type workload =
  { domain : string
  ; name : string
  ; primitive : string
  ; image : string
  ; config : (string * string) list
  ; secrets : (string * string) list
  ; schedule : string option
  ; replicas : int
  ; cpu : string
  ; memory : string
  ; extra_labels : (string * string) list
  }

type t =
  { release_id : string
  ; workspace : string
  ; environment : string option
  ; workloads : workload list
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
    validate the record in both directions. *)
val of_plan : Sol_cli_deployment_plan.t -> t

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

(** Parse [kubectl get configmap -l … -o json]. Fails closed (FEAT-071): a
    matching record that is missing, malformed, or fails {!validate} is
    corruption and returns an [Error] naming it, rather than a short list that
    reads as the whole history. *)
val parse_kubectl_list : Yojson.Safe.t -> (t list, string) result

(** An aligned [ID / ENV / WORKLOADS] table, ordered by id. *)
val format_table : t list -> string
