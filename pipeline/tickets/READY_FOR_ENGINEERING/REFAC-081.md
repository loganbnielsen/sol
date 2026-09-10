---
id: REFAC-081
type: refactor
severity: low
source: 2026-09-09 code-layer audit finding 7; REFAC-043 verification
---

**Depends on:** None.

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
