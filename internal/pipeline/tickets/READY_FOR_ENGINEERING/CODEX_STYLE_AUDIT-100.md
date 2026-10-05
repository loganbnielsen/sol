---
id: CODEX_STYLE_AUDIT-100
type: bug
severity: medium
title: "Preserve local service child outcomes and own their shutdown as one lifecycle"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Preserve local service child outcomes and own their shutdown as one lifecycle

**Depends on:** None.

**Principles:** 6, 14, 20–25, 31, 32, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/bin/cmd_local.ml:317`: launch_services filters failed spawns out and succeeds when any child starts.
- `:350`: supervise_children logs nonzero exits but always returns Ok; its wait loop decrements even for unowned children.
- Signal shutdown kills remembered shell PIDs and sleeps before SIGKILL, without restoring the prior signal handler or proving descendants are gone.
- `:294` and `:317`: already structured recipe argv/cwd is serialized into sh -c commands. `resolve_run` also changes global cwd.

## Mechanism and impact

Partial launch is reported as services running, and eventual child failure becomes successful command completion. Raw PIDs replace the process ownership handle. Shell interposition makes descendant cleanup and status attribution less reliable even though a validated recipe already carries argv/cwd. The documented phase split improves readability but does not preserve terminal outcomes.

## Remediation

Move the bounded launch/supervision policy into the owning local runtime operation with typed child outcomes. Execute recipes through argv/cwd process support, retain owned child handles, fail and clean up on partial startup, aggregate terminal statuses intentionally, and restore signal state during cleanup. Avoid a generic orchestration framework; preserve interactive output and interrupt behavior.

## Acceptance criteria

- One failed spawn after another starts stops/reaps owned children and returns nonzero with cause.
- A nonzero child exit or unexpected signal cannot yield successful command completion.
- Reap only owned children; unrelated child termination cannot decrement the owned set.
- SIGINT/SIGTERM shutdown leaves no owned descendants and restores signal ownership.
- Paths with spaces/metacharacters use literal argv/cwd semantics.
- Verify both OCaml and TypeScript launch recipes with offline subprocess fixtures.

- Demo/example: update the runnable local-run example and its failure/shutdown guidance.
- Language parity: check both language recipes; record shared lifecycle semantics.

## Existing work and scope

REFAC-153 completed named local-run phases; REFAC-134 introduced the common runner. Neither open ticket owns these remaining lifecycle outcomes. CODE_LAYER-030/032 concern maintainer shell helpers, not this command controller.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
