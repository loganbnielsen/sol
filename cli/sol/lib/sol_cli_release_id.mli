(** The content-addressed identity of a release (FEAT-069).

    A release is *what is running* — the desired released state, canonicalised
    and hashed. Identical content is one release however many times it is
    deployed; a deploy is a *deployment event* (FEAT-070), which is a different
    object with its own minted id and provenance.

    {2 Why content-addressed}

    The id is rendered into the pod template as a label. A minted-per-deploy id
    would therefore change the template on every deploy and force a rollout even
    when nothing substantive changed — the observability metadata would cause the
    mutation it exists to observe. Content addressing makes "same desired
    workload" mean "same id" and therefore "no rollout merely because Sol ran
    again", which is also what keeps a GitOps bundle an empty diff.

    {2 What is part of the identity}

    Only fields whose difference means {i this is a different running release}:
    the workspace, the environment, and per workload its identity, image,
    config, secret {i references}, schedule, replicas, resources and extra
    labels. Provenance (timestamp, commit, actor, output directory) is
    deliberately absent — it belongs to the deployment event, and excluding it
    here is what stops a field added to the plan from silently changing every
    release identity.

    Secret {i values} are likewise absent: rotating a secret does not by itself
    change the release, because secrets are operational state rather than release
    content. This is a rule, and it is tested, so that "fixing" the hash later
    cannot silently change what a release identity means. *)

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

type content =
  { workspace : string
  ; environment : string option
  ; workloads : workload list
  }

(** A legal Kubernetes label value by construction ({i r-<16 hex>}), so labels
    are written verbatim and can never drift from the stored id. *)
type t

(** [of_content content] is the release identity of that content. Pure: the same
    content always yields the same id, and ordering that carries no meaning
    (workload discovery order, config/secret key order) does not affect it. *)
val of_content : content -> t

val to_string : t -> string

(** [of_string] validates the shape, so a deserialised or hand-written id cannot
    be a value the label could not carry. *)
val of_string : string -> (t, string) result

(** The canonical encoding that is hashed. Exposed for tests and diagnostics
    only: the *encoding* is not a stable contract and may change (deliberately,
    via {!encoding_version}) — only the identity semantics it implements are. *)
val canonical_string : content -> string
