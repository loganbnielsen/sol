(** YAML that Sol writes, built as a value and rendered once (REFAC-131).

    A manifest is never assembled by interpolating text into a template: every
    scalar goes through {!string}, {!quoted}, {!int} or {!bool}, so a value
    containing a quote, a backslash, a newline or [": "] is written as exactly
    that value, and a value such as [true], [null] or [1.10] stays a string.
    Rendering is libyaml's emitter, through [ocaml-yaml].

    A NUL character cannot be written (libyaml takes C strings): every scalar
    constructor raises [Invalid_argument] on one, rather than let it truncate the
    value. The boundaries that decode user text refuse it first. *)

type t

(** A string, written plain when nothing could read it as another type or as YAML
    syntax, and double-quoted otherwise. The plain form is kept for the common
    case (names, images, quantities such as [100m]) so rendered manifests stay
    readable; the rule is deliberately conservative -- anything that YAML 1.1
    (which Kubernetes' decoder follows) could resolve to a boolean, null or number,
    anything with a space, and anything starting with an indicator, is quoted. *)
val string : string -> t

(** A string, always double-quoted: for values Sol has always quoted (env values,
    labels, annotations), whatever their text. *)
val quoted : string -> t

(** Multi-line text as a literal block scalar ([|]), for a file carried inside a
    manifest (a dashboard's JSON, a config file). The text round-trips exactly,
    trailing newlines included; libyaml picks the chomping indicator. *)
val literal : string -> t

val int : int -> t
val bool : bool -> t

(** A block mapping, in the order given. An empty mapping renders as [{}]. *)
val map : (string * t) list -> t

(** A block sequence. An empty sequence renders as [[]]. *)
val list : t list -> t

(** [plain_safe s]: {!string} writes [s] without quotes. Exposed for tests. *)
val plain_safe : string -> bool

(** One YAML document, with optional comment lines written after its [---]. *)
type document

val document : ?comments:string list -> t -> document

(** [to_string v]: [v] alone, with no document marker -- a whole file that is
    itself YAML (Helm values, a Grafana provisioning file). *)
val to_string : t -> string

(** [render docs]: each document as ["---\n"], its comments, then its body.
    The empty list renders as [""]. *)
val render : document list -> string
