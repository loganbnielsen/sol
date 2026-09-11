---
id: REFAC-016
type: refactor
severity: medium
source: codebase simplification review 2026-06-15
branch: REFAC-016/extract-signal-handler
worktree: /home/lbendtly/Code/sun-REFAC-016-extract-signal-handler
---

Extract self-pipe signal handler to a shared framework module

**Depends on:** None.

**Description:**

All three framework entry points implement identical self-pipe SIGTERM/SIGINT handling. The same ~10-line block appears in:

| File | Lines |
|------|-------|
| `framework/sun-svc/lib/service.ml` | 137–151 |
| `framework/sun-worker/lib/worker.ml` | 27–42 |
| `framework/sun-fn/lib/fn.ml` | 14–32 |

Every copy does: `Unix.pipe ~cloexec:true`, `Unix.set_nonblock w`, a one-byte write signal handler, `Sys.set_signal Sys.sigterm`, `Sys.set_signal Sys.sigint`, and an Eio fiber that reads from the pipe. The copies differ only in what they do once the signal fires: `service.ml` resolves a promise; `worker.ml` sets an `Atomic.t`; `fn.ml` resolves a promise and returns `Stop_daemon`.

**Remediation:**

Add a `Sun_signal` module. The natural home is a new `framework/sun-core/` package (shared by all three framework libs) or, if adding a package is too much churn, directly into whichever framework lib the others already depend on.

```ocaml
(** Install SIGTERM + SIGINT handlers using a self-pipe.
    Calls [on_signal ()] from an Eio fiber on the first signal received.
    The fiber runs on [sw]; cancelling [sw] stops it. *)
val install :
  sw:_ Eio.Switch.t ->
  on_signal:(unit -> unit) ->
  unit
```

Each framework module passes a different `on_signal` callback:
- `service.ml`: `(fun () -> Eio.Promise.resolve resolver ())`
- `worker.ml`: `(fun () -> Atomic.set stop true)`
- `fn.ml`: `(fun () -> Eio.Promise.resolve resolver Stop_daemon)`

**Acceptance criteria:**

- `service.ml`, `worker.ml`, and `fn.ml` contain no local `Unix.pipe` self-pipe boilerplate.
- `Sun_signal.install` (or equivalent) is the single implementation.
- `dune build` passes and all three framework packages compile.
- Unit tests pass (`dune test framework/`).

## Review — automated checks passed
REFAC-016 correctly extracts self-pipe signal handling into Sun_signal.install; build and framework tests pass
