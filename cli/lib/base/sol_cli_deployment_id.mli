(** The minted identity of one deployment event (FEAT-070).

    A release is *what is running* and is content-addressed (FEAT-069), so two
    deploys of identical content share one release id. A deployment is *one
    invocation*, and its id is minted rather than derived: every attempt gets a
    fresh id even when it puts the same release in place. That asymmetry is the
    point of the split, not an implementation detail.

    The id is [d-<YYYYMMDDtHHMMSSz>-<16 lowercase hex>]. The UTC prefix makes
    lexical order (roughly) deployment order, which is what keeps a plain
    [kubectl get configmap -l sol.dev/type=deployment] readable; the hex suffix
    is minted entropy so two independent actors deploying in the same second do
    not collide. The timestamp inside the id is for sorting and ergonomics only:
    [created_at] on the event is the authoritative timestamp and is never
    reconstructed by parsing the id.

    The time is lowercase ([t]/[z]) deliberately: the id is embedded verbatim in
    the ConfigMap name [sol-deployment-<id>], and Kubernetes object names are
    lowercase RFC 1123. Uppercase would be legal in a label value and not in a
    name, so the id itself is the legal one. *)

type t

(** [create ~now ~entropy] mints an id. It is deterministic for a given [now]
    and [entropy], so tests can pin it; production passes [random_entropy ()]. *)
val create : now:float -> entropy:string -> t

(** 16 bytes of OS entropy where available, with a weaker fallback. The id is
    not a security token; the requirement is collision-resistance across
    independent deploying actors, for which 64 bits of entropy is ample. *)
val random_entropy : unit -> string

val to_string : t -> string

(** Validates [d-<YYYYMMDDtHHMMSSz>-<16 lowercase hex>]. *)
val of_string : string -> (t, string) result
