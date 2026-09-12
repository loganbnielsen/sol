---
id: REFAC-081
type: refactor
severity: low
source: 2026-09-09 code-layer audit finding 7; REFAC-043 verification
---

**Depends on:** None.

**Premise checked 2026-09-12:** the self-pipe body was still present verbatim in `framework/sol-svc/lib/service.ml`, `framework/sol-worker/lib/worker.ml`, and `framework/sol-fn/lib/fn.ml`.

Complete the self-pipe signal-handler extraction that REFAC-043 claimed but did not land: `install_signal_handler` is still duplicated across all three primitives.

## Problem

`install_signal_handler` is implemented independently in:

- `framework/sol-svc/lib/service.ml:180`
- `framework/sol-worker/lib/worker.ml:53`
- `framework/sol-fn/lib/fn.ml:26`

REFAC-043 ("Extract self-pipe signal handler into shared `Sun_signal` module") is in `DONE`, and its acceptance criterion was that `grep -rn "Unix.pipe\|set_nonblock\|sigterm" framework/sol-svc framework/sol-worker framework/sol-fn` return zero hits in `lib/`. That is not true today, and the 2026-09-09 code-layer audit re-reported the duplication as finding 7. This is the same "DONE but not actually live" class as EXP-032 — verify with `soldev pipeline check-reverts` and treat REFAC-043 as not resolved.

The self-pipe trick has subtle correctness requirements (non-blocking write, cloexec, async-signal safety); three copies mean any fix must be applied three times.

## Goal

One implementation of the signal/self-pipe handling, called by all three primitives, with a check that prevents the duplication from silently returning.

## Remediation

- Create a shared module (`framework/sol-signal`, as REFAC-043 proposed) with the two resolver variants (`Eio.Promise.u` for svc/fn, `Atomic.bool` for worker), add it to the dune deps, and replace the three bodies.
- If extraction is judged not worth it, make that an explicit decision instead: reduce to one documented copy plus a comment, and correct REFAC-043's record.
- Add a regression check (grep-based or a test) so the three-copy state cannot come back unnoticed.

## Acceptance criteria

- No primitive contains an independent self-pipe body; the REFAC-043 acceptance grep holds.
- `dune build framework/` and `dune test framework/` pass.
- A check (test or CI grep) fails if the duplication returns.

## Finding before implementation (2026-09-11): the shared *home* is an unmade decision

The duplication is confirmed — `install_signal_handler` exists in `sol-svc`, `sol-worker` and `sol-fn`, and the self-pipe shape is identical (a byte written from the signal handler, an Eio fiber awaiting readability on the read end, resolving a stop promise the consumer checks at a message boundary so the in-flight message finishes).

What this ticket did not settle is **where the extracted version lives**, and the tree does not answer it:

- All three primitives already depend on **`sol_obs`** — but that package is observability (metrics, logs, traces), and a shutdown handler is not observation. Putting it there would be a naming lie that outlives the convenience.
- **`sol_env`** is the existing shared package, but it is `(modules_without_implementation sol_env)` — an interface package by design. Adding an implementation changes what it is.
- A new package (`sol-runtime`) is the conceptually clean home, and it is a **packaging** change: opam metadata plus the release and publish path, not a refactor.

So this ticket is gated on one decision: *which package owns shared runtime behaviour that is neither observability nor an interface?* My recommendation is the new package, taken deliberately rather than as a drive-by, because this will not be the last such piece — the same question recurs for anything a service and a worker both need.

**The extraction is also not purely mechanical.** The three copies differ in their surrounding control flow (`Eio.Switch.run` in one, the consumer's own loop in another), so the shared signature has to be chosen by what all three can call — and the tests should assert the shutdown *behaviour* (the promise resolves, the in-flight message completes) rather than the helper's internals, or the refactor will be verified by nothing.

## Decision — the shared home (settles the 2026-09-11 finding)

`framework/sol-runtime/`, as an in-tree dune library. Not a new opam package, and
not `sol_obs` or `sol_env`.

The finding assumed a new package was "a packaging change: opam metadata plus the
release and publish path". That is not true of this repo's model: the primitives
are dune libraries inside the single `(package sol)` stanza in `dune-project`
(`(generate_opam_files true)`), so adding `framework/sol-runtime/` adds no opam
metadata and no release path. `sol_obs` would read as observation, which a
shutdown handler is not, and `sol_env` is deliberately
`(modules_without_implementation)`. A small dedicated runtime library is the
honest home, and it is where the next shared primitive behaviour should go.

Correction: the finding said the worker needed an `Atomic.bool` variant. It does
not — all three copies take `Eio.Promise.u` and update a stop promise, so one
variant is the whole surface.

## Completion notes

Landed 2026-09-12.

- New `framework/sol-runtime/` (`Sol_runtime.install_signal_handler`): one
  self-pipe body. It uses `fork_daemon`, which worker/fn already used; svc's
  `fork` became the daemon form too, so a service that exits for a reason other
  than a signal cannot hang its switch on a fiber waiting for a signal that
  never comes.
- `sol-svc`, `sol-worker` and `sol-fn` call it and carry a one-line pointer
  instead of a body.
- `framework/sol-runtime/test/test_signal.ml` asserts the *behaviour*: a real
  `SIGTERM`/`SIGINT` resolves the stop promise. A five-second timeout means a
  broken handler fails the test instead of hanging it.
- `devtools/ci/check_signal_handler_duplication.sh` greps the three primitive
  `lib/` dirs for `Unix.pipe` / `Unix.set_nonblock` / `Sys.set_signal` and fails
  if the shape returns; it is wired into the `test` job. This is the check
  REFAC-043's acceptance grep claimed but never had.

Verified: `dune build`, the new behaviour test, and the CI unit-test set
(`framework/sol-env sol-fn sol-obs sol-runtime sol-svc sol-worker cli/sol/test`)
all pass; `dune fmt --preview` is clean.

Demo/example coverage: internal refactor with no app-author-facing surface — the
one-line exemption the repo's demo rule allows.
