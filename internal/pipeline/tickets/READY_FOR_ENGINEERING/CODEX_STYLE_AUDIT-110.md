---
id: CODEX_STYLE_AUDIT-110
type: documentation
severity: low
title: "Align reusable audit criteria with current lifecycle and secret contracts"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Align reusable audit criteria with current lifecycle and secret contracts

**Depends on:** None.

**Principles:** 15, 19, 33, 37 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `internal/pipeline/audits/AUDIT.md:19` promises no half-deployed state on every deploy failure; later lifecycle/recovery decisions permit observed partial failure and recovery.
- The template still names cli/sol paths, quotes Sys.command as the shell-safety standard, and uses older ack APIs/runbook commands.
- `internal/pipeline/audits/STYLE_AUDIT.md:112` and its secret-strategy table describe ordinary deployment rendering plaintext, while BUG-054 now makes Kubernetes_live consume operator-owned Secrets.
- Current CONTRIBUTING conventions and later decisions provide stricter/current boundaries.

## Mechanism and impact

A future reviewer can file false defects or accept weak behavior by following obsolete reusable criteria. Historical reports may retain old facts; the live blank exam must not claim obsolete invariants or commands.

## Remediation

Reconcile the reusable audit criteria against current decisions and source. State prevalidation, typed failure, ownership, recovery, and cleanup contracts precisely instead of universal rollback promises. Replace obsolete paths/API examples and secret descriptions; distinguish static review from required live evidence.

## Acceptance criteria

- Every active criterion references current paths and supported commands/APIs.
- Secret authority agrees with BUG-054/current renderer and the relevant decision records.
- Lifecycle failure criteria specify actual guarantees and recovery, without implying unimplemented atomic rollback.
- Structured argv execution is the subprocess safety baseline.
- Historical findings remain identifiable as historical; do not rewrite their original evidence.
- Manually verify updated snippets against command help/source and document live-only checks.

- Demo/example: not applicable: internal review documentation; verify all runnable snippets that the criteria do contain.
- Language parity: criteria must explicitly retain both language behavioral contracts.

## Existing work and scope

This ticket maintains source-of-truth review criteria, not broad user-doc rewriting. No matching open owner was found; REFAC-140/141 are implementation work, not audit-template truth.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
