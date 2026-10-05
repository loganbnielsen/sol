---
id: CODEX_STYLE_AUDIT-108
type: bug
severity: medium
title: "Resolve all support-reference updates before mutating dependency declarations"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Resolve all support-reference updates before mutating dependency declarations

**Depends on:** None.

**Principles:** 6, 15, 20–24, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `internal/tooling/scripts/bump-support-refs.sh:18`: resolves one package then immediately sed-edits tracked opam pins.
- `:21`: later failed resolution exits before copying the accumulated support-refs file.
- `:33`: authoritative list is written only at the end; set -uo pipefail does not automatically abort sed/cp failures.

## Mechanism and impact

A later remote resolution failure can leave opam pins updated while support-refs.txt retains old commits. Write failures can also produce inconsistent declarations or misleading completion. Resolution and mutation are mixed in one loop.

## Remediation

Resolve/validate the entire requested package set first, derive coherent staged contents, then apply the file set with explicit failure handling and owned temporary cleanup. Diagnose unknown requested packages. Preserve or restore the coherent original set if installation fails; do not claim all-or-nothing merely because individual replacements are atomic.

## Acceptance criteria

- Failure resolving the second package leaves all repository files unchanged.
- Failed write returns nonzero and leaves a coherent recoverable set.
- Success synchronizes the reference list and all intended opam pins.
- Unknown requested packages fail explicitly.
- Offline fake remote/write fixtures exercise these phases without network or real dependency changes.

- Demo/example: not applicable: maintainer tooling.
- Language parity: no language-parity impact.

## Existing work and scope

No open matching owner was found. This is maintainer dependency-update atomicity, not support-package API redesign.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
