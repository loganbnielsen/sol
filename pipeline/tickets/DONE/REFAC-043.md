---
id: REFAC-043
type: refactor
severity: high
source: codebase simplification review 2026-06-16
branch: REFAC-043/extract-signal-handler
worktree: ../sun-REFAC-043-extract-signal-handler
---

Extract self-pipe signal handler into shared `Sun_signal` module

**Depends on:** None.

**Description:**

All three framework primitives contain near-identical `install_signal_handler` functions (~20 lines each) that implement the self-pipe trick for SIGTERM/SIGINT:

- `framework/sun-svc/lib/service.ml:~130–152`
- `framework/sun-worker/lib/worker.ml:~25–45`
- `framework/sun-fn/lib/fn.ml:~20–40`

The bodies are structurally identical: `Unix.pipe ~cloexec:true`, `Unix.set_nonblock w`, `Sys.set_signal Sys.sigterm`, `Sys.set_signal Sys.sigint`, `Eio_unix.await_readable r`, drain pipe, resolve outcome. The only variation is the final resolution: svc and fn resolve an `Eio.Promise.u`, while worker sets an `Atomic.bool`.

The self-pipe trick has subtle correctness requirements (non-blocking write, cloexec, async-signal safety). Having three independent copies means a fix or improvement (e.g., handling SIGHUP, improving the drain loop) must be applied in three places.

**Remediation:**

1. Create `framework/sun-signal/lib/sun_signal.ml` (new small package) with two public functions:
   - `install_promise_handler : sw:_ Eio.Switch.t -> unit Eio.Promise.u -> unit` (used by svc and fn)
   - `install_atomic_handler : sw:_ Eio.Switch.t -> bool Atomic.t -> unit` (used by worker)
2. Add the package to `dune-project` and add a `dune` file for it.
3. Add `sun-signal` as a dependency of `sun-svc`, `sun-worker`, and `sun-fn` in their respective `dune` files.
4. Replace the three `install_signal_handler` bodies with calls to the appropriate `Sun_signal` function.

**Acceptance criteria:**

- `grep -rn "Unix.pipe\|set_nonblock\|sigterm" framework/sun-svc framework/sun-worker framework/sun-fn` returns zero hits in `lib/` files.
- `dune build framework/` passes.
- `dune test framework/` passes.

## Review — automated checks passed
fork_daemon comment present, Fun.protect guarantees cleanup, build/tests clean, no signal handler boilerplate in framework lib files, project/tickets untouched

## Review — automated checks passed
fork_daemon comment present, Fun.protect guarantees cleanup, build/tests clean, no signal handler boilerplate in framework lib files
