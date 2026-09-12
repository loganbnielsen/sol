(** Shared runtime behaviour for Sol's service primitives (REFAC-081).

    The home is deliberately a small, in-tree [sol-runtime] dune library rather
    than [sol_obs] (a shutdown handler is not observation) or [sol_env]
    (interface-only by design). It is not a publishing change: the primitives
    are libraries inside the single [sol] opam package, so this adds no opam
    metadata and no release path. *)

(** [install_signal_handler ~sw resolver] installs handlers for SIGTERM and
    SIGINT that resolve [resolver] exactly once, and forks a daemon fiber on
    [sw] that awaits the self-pipe and then exits.

    The write end of the self-pipe is non-blocking and cloexec, and the handler
    only performs an async-signal-safe single-byte write. Consumers await the
    resolved promise at a message boundary, so an in-flight message completes
    before shutdown. *)
val install_signal_handler : sw:Eio.Switch.t -> unit Eio.Promise.u -> unit
