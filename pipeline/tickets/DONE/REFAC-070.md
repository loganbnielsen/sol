---
id: REFAC-070
type: refactor
severity: medium
source: cross-cutting-design-review 2026-08-31
branch: refac-068-070-cleanup
worktree: none (direct main-checkout branch, no linked worktree)
pr: https://github.com/loganbnielsen/sun/pull/65
---

Remove worker test injection from the public runner signature

**Depends on:** REFAC-067.

## Problem

`Worker.Make(W).run` exposes `?test_consume_loop`, a test seam that replaces the
real Kafka consume loop. It keeps unit tests fast, but it is not a user-facing
feature.

## Goal

Preserve fast worker unit tests without making test injection part of the
normal public API.

## Acceptance criteria

- Normal `Worker.Make(W).run` no longer exposes `?test_consume_loop`.
- Unit tests still exercise handler wrapping, metrics, stop, max-message, and
  ack failure behavior without a live broker.
- Kafka integration tests continue to cover the real consume path.
