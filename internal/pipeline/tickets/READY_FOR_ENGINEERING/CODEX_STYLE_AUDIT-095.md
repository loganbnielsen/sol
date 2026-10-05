---
id: CODEX_STYLE_AUDIT-095
type: bug
severity: medium
title: "Reject malformed boundary lease coordination state before decisions or formatting"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Reject malformed boundary lease coordination state before decisions or formatting

**Depends on:** None.

**Principles:** 1, 2, 7, 21, 23, 24, 34, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/lib/deploy/sol_cli_boundary_lease.ml:122`: float_of_string_opt accepts nonfinite timestamps.
- `:186`: parsed floats alone establish valid lease times; malformed abort_requested becomes false.
- `:61`: NaN/infinity defeat meaningful staleness comparison.
- `:65` and `:79`: refusal describes external started_at using time formatting.
- `cli/lib/base/sol_cli_time.ml:1`: an unrepresentable timestamp raises Invalid_argument.
- Decoder accepts missing/blank run_id and resourceVersion.

## Mechanism and impact

Malformed stored coordination state can remain nonstale indefinitely, suppress an abort, or raise while a Result-returning acquisition tries to explain its refusal. Missing CAS identity also becomes a valid-looking observation.

## Remediation

Strictly decode required lease fields into validated coordination state: finite representable times, nonblank identity/version, and explicit boolean parsing. Diagnose field/path failures before staleness, takeover, abort, or formatting. Do not add legacy defaults without an actual current contract need.

## Acceptance criteria

- NaN, infinities, unrepresentable times, malformed abort text, blank run ID, and absent CAS metadata return contextual Error.
- No malformed lease reaches decision/formatter code.
- Acquire, heartbeat, abort, rollback, and CAS conflict tests retain their ordering and behavior.
- Expected external-data rejection never raises Invalid_argument.

- Demo/example: not applicable if confined to internal lease storage; record that in completion notes.
- Language parity: no language-parity impact: shared CLI coordination storage.

## Existing work and scope

BUG-071 covers takeover safety, not external coordination decoding. No matching open owner was found.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
