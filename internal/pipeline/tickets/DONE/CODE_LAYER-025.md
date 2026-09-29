---
id: CODE_LAYER-025
type: refactor
severity: medium
title: Keep subprocess ownership exception-safe when capture is interrupted
source: internal/pipeline/audits/2026-09-28_deep_code_quality_audit.md
---

Keep subprocess ownership exception-safe when capture is interrupted

**Depends on:** None.

**Premise verified (2026-09-28):** Traced `cli/lib/base/sol_cli_process.ml:133,224-237; internal/tooling/sol_process/lib/sol_process.ml:64,118-123` with callers and existing tests at origin/main `2dfa5694`. Evidence and reproduction limits are recorded in the source audit.

## Problem

Both capture loops call Unix.select without EINTR handling, and both runners close read descriptors/reap the child only after capture returns normally. An innocuous handled signal raises Interrupted system call from run, leaks two descriptors and leaves the child unreaped. This violates the runner result boundary and leaks ownership during cancellation/errors.

## Remediation

Retry EINTR while retaining the deadline and protect descriptors/child ownership through exceptional exits. Preserve cancellation semantics: cleanup before propagating cancellation, rather than silently converting it to success. Repair the existing runners instead of adding per-caller recovery.

## Acceptance criteria

- A handled signal during capture returns the expected command result without leaked descriptors or children; explicit interruption/cancellation cleans up before propagating. Include signal-free and deadline positive controls for both runner implementations. Internal tooling refactor: record no demo or language-parity impact.
- Record the application demo and per-language verdict in completion notes wherever the change affects an application contract.

## Completion (2026-09-29)

- **Premise re-verified** at origin/main `788e688d`: both capture loops called `Unix.select` without EINTR handling, and both runners closed the read descriptors and reaped the child only on the normal path. The audit's probe reproduced `select: Interrupted system call fd_delta=2` with a child left for a later `waitpid`.
- **Fix.** `select_ready` retries `Unix.select` on `EINTR` while recomputing the remaining deadline (the strict "deadline passed ⇒ timed out" semantics are preserved), and `wait_reap`/`wait_reap_wnohang` make child reaping EINTR-safe. Both `Sol_cli_process.run` and `Sol_process.run_argv` now wrap capture and exit in `Fun.protect`, whose `finally` closes both read descriptors and kills-and-reaps the child if the body left before completion — so an exceptional exit cannot leak descriptors or a running child, and cancellation still propagates rather than being swallowed.
- **Tests** (both runners): a no-op `SIGALRM` handler fires mid-capture and the command still completes with its output and no descriptor growth (`/proc/self/fd` count unchanged) — the previous code raised `EINTR` out of `run`; a raising handler interrupts the command, the exception propagates, and both the descriptor count and an unreaped-child probe confirm cleanup. Signal-free and deadline paths are the existing plus BUG-068 controls.
- Validation: full `dune build`; `test_process.exe` 23/23 and `test_sol_process.exe` 23/23 pass; `dune fmt --preview` clean; no-comments policy holds.
- **Demo/example: not applicable** — internal subprocess ownership. No language-parity impact: no framework or application contract changes.
