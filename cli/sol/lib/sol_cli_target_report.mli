(** Rendering a deployment target as a target — provider, region, cluster, and
    whether Kubernetes is reachable — rather than as kubectl output (FEAT-062).

    Pure by construction: reachability is obtained by the caller and passed in,
    so the default offline rendering is what the tests exercise. *)

(** What is known about reaching this target's cluster. *)
type kubernetes_status =
  | Not_configured (** The target names no kube_context, so there is no destination. *)
  | Configured of string
  (** A destination exists and was not probed ([--check] was not passed). *)
  | Reachable of string
  | Unreachable of string * string (** Context and the reason it could not be reached. *)

(** [describe ~verbose status] is the one-line Kubernetes summary. The raw
    context appears only when [verbose], since it is a mechanism rather than the
    target's identity (DEC-020). *)
val describe : verbose:bool -> kubernetes_status -> string

(** Label/value rows for display. The raw kube-context appears only when
    [verbose], since it is a mechanism, not the target's identity (DEC-020). *)
val rows
  :  verbose:bool
  -> Sol_cli_config.target
  -> kubernetes_status
  -> (string * string) list

(** The same rows as JSON. *)
val to_json : verbose:bool -> Sol_cli_config.target -> kubernetes_status -> Yojson.Safe.t
