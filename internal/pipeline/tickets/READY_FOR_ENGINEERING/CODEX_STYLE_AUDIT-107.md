---
id: CODEX_STYLE_AUDIT-107
type: infra
severity: medium
title: "Validate qualification transaction responses structurally before declaring worker success"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Validate qualification transaction responses structurally before declaring worker success

**Depends on:** None.

**Principles:** 1, 2, 15, 21, 22, 33, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `internal/qualification/aws/app-transaction.sh:35`: formatting-sensitive sed extracts charge ID without requiring a nonempty result.
- `:41`: failed notifications curl becomes empty text; the pattern containing an empty ID matches any result and emits the success sentinel.
- Outer script accepts that log sentinel. aws/live-row.sh:398 still invokes the path when transport is unset.
- transport-transaction.sh:81 rejects empty ID, but read-back still matches textual substrings; orders status checks are also textual.

## Mechanism and impact

The campaign can report a worker effect without a validated operation identity or successful matching read-back. Alternate JSON formatting can cause false failure, while empty/unrelated text can cause false success. Qualification evidence must establish the semantic transaction, not the existence of a sentinel line.

## Remediation

Parse transaction responses structurally, require correctly typed nonempty operation identity, and check successful exact matching domain effect. Share the semantic predicate between in-cluster and transport execution without sharing transport authority. Preserve response/error evidence on failure.

## Acceptance criteria

- Malformed JSON, absent/empty ID, alternate whitespace, failed read-back, and unrelated result cannot emit success.
- Valid exact matching effect succeeds.
- Both charges and orders paths validate identity/status fields structurally.
- Offline HTTP/Job-log fixtures cover both transport paths; no paid cloud run is required.

- Demo/example: not applicable: qualification-only semantic assertion; update harness documentation.
- Language parity: transaction evidence must validate the declared scenario independently of implementation language.

## Existing work and scope

INFRA-107 owns attempt/endpoint binding of observer evidence; this ticket owns application transaction truth. No open matching owner was found.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
