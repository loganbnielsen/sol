(** Shared runtime behaviour for Sol's service primitives (REFAC-081).

    The home is deliberately a small, in-tree [sol-runtime] dune library rather
    than [sol_obs] (a shutdown handler is not observation) or [sol_env]
    (interface-only by design). It is not a publishing change: the primitives
    are libraries inside the single [sol] opam package, so this adds no opam
    metadata and no release path. *)

(** [install_signal_handler ~sw resolver] registers [resolver] with the
    process-wide SIGTERM/SIGINT handler (installed on the first registration)
    and forks a daemon fiber on [sw] that awaits this registration's self-pipe,
    resolves [resolver] once, and exits. Every live registration is signalled,
    so several primitives in one process all shut down (BUG-047). The
    registration ends when [sw] does: its fd is removed from the handler before
    it is closed, and when none remain the previous dispositions are restored.
    A second signal while the first is being handled restores the default
    disposition and re-raises it, so a second Ctrl-C terminates the process.

    The write end of the self-pipe is non-blocking and cloexec, and the handler
    only performs an async-signal-safe single-byte write. Consumers await the
    resolved promise at a message boundary, so an in-flight message completes
    before shutdown. *)
val install_signal_handler : sw:Eio.Switch.t -> unit Eio.Promise.u -> unit
