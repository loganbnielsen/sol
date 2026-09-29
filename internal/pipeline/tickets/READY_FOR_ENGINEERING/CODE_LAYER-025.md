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
