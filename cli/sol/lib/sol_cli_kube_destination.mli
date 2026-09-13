(** How Sol reaches the cluster a target names — the *mechanism*, not an
    identity.

    A kube-context is a client-side handle: it bundles a cluster reference,
    credentials and optionally a namespace, and it can be renamed without the
    cluster changing. So nothing here proves *which* physical cluster a
    destination resolves to. DEC-020 trusts the configured destination;
    proving identity is deliberately out of scope (FEAT-058).

    Every Kubernetes operation is scoped with these arguments rather than
    inheriting [kubectl]'s current context, so the destination is a function of
    the selected target and never of the machine's ambient state. *)

type t =
  { context : string
  ; kubeconfig : string option
  }

(** For messages: the context, plus the kubeconfig when one is scoped. *)
val to_string : t -> string

(** [of_context ~kubeconfig ctx] is [Ok t] when [ctx] is a non-empty,
    non-whitespace context name, and [Error message] otherwise.

    Fails closed on purpose: an empty context means the configuration did not
    say where this target deploys. Defaulting to "whatever kubectl is pointing
    at" is exactly the hidden input DEC-020 removes, so it is a configuration
    error with an explanation rather than a fallback. *)
val of_context : ?kubeconfig:string -> string -> (t, string) result

(** The ephemeral local cluster, [k3d-sol-local]. Sol owns that cluster, so
    naming it literally is the one default that cannot be ambiguous. *)
val local : t

(** [["--context"; ctx]] — appended to every kubectl invocation. *)
val kubectl_args : t -> string list

(** [["--kube-context"; ctx]] — helm's spelling of the same thing. *)
val helm_args : t -> string list

(** Environment for the child process: [KUBECONFIG] when a kubeconfig is
    scoped. Preferring a scoped kubeconfig where practical also keeps other
    environments' credentials out of the process. *)
val environment : t -> (string * string) list

(** FEAT-063: the destination-side value threaded through the operation helpers,
    so a reader of any cluster-touching module can see which cluster it reaches.

    This is a record rather than a bare {!t} so the next destination-side input
    (credential scoping) rides the same channel instead of forcing a second
    refactor over the same call graph. It carries destination-side facts only:
    *where* an operation reaches a cluster, never *what* is being deployed —
    scope travels separately (FEAT-061), so the Kubernetes seam never learns the
    workload set. *)
type context = { destination : t }

val context_of_destination : t -> context

(** The literal local cluster, [k3d-sol-local] — the one default that cannot be
    ambiguous, because Sol owns it. *)
val local_context : context

val kubectl_context_args : context -> string list
val helm_context_args : context -> string list
val context_environment : context -> (string * string) list
val context_to_string : context -> string

(** The full child environment — the ambient one with the destination's
    [KUBECONFIG] override applied — for [Unix.execvpe] / [Unix.create_process_env],
    which take a whole environment rather than a delta. Use this wherever kubectl
    is spawned directly rather than through {!Sol_cli_kubectl}, so an exec path
    cannot apply [--context] while forgetting the kubeconfig. *)
val child_environment : context -> string array
