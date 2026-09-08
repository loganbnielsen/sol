---
id: FRIC-009
type: dogfood-finding
severity: medium
source: FRIC-007's remediation item 3 (project/tickets/DONE/FRIC-007.md) — split out rather than bundled into that fix, since CI/CD pipeline changes warrant their own dedicated review
branch: fric-009/golden-path-ci-smoke-test
worktree: ../sol-fric-009-golden-path-ci-smoke-test
pr: https://github.com/loganbnielsen/sol/pull/142
---

**Depends on:** None.

Add a minimal golden-path regression check to CI so a class of bug like FRIC-007 (every generated Sol service permanently broken by a Kafka schema-registry version incompatibility) is caught automatically instead of requiring a manual dogfood pass to discover.

## Why this is a separate ticket

FRIC-007 (Redpanda 24.1.8 rejecting `schemaType: "JSON"` schema registration, crash-looping every generated service on any fresh substrate) reproduced deterministically on a completely fresh `sol dev up` + `sol new workspace`, with zero modification — nothing in CI caught it because nothing in CI runs the actual golden path against live infra. That fix (the version bump + chart-values correction) is scoped narrowly to the root cause; adding CI infrastructure to catch this *class* of regression is real, valuable, but meaningfully different work — it touches shared CI/CD pipeline configuration, which warrants its own dedicated review rather than riding along on the version-bump fix.

## Scope

A minimal smoke test, gated to run only when Docker/k3d are actually available in the CI environment (don't fail CI outright on runners without that capability — skip cleanly):

1. `sol new workspace` a throwaway workspace.
2. `sol dev up` against a fresh substrate (this is the part that actually exercises real Kafka schema registration against a real broker — the part FRIC-007 broke).
3. `sol up`.
4. A single `curl /health` (or equivalent) confirming the generated service actually started, not just that the CLI commands exited 0.

This does not need to be the full golden-path dogfood run (no need to also check `sol migrate`, the Kafka→worker→notification round-trip, `sol status`, etc. — that's what `/dogfood` is for). The goal is narrow: catch "every generated service is permanently broken on a fresh substrate" specifically, since that's the failure mode that was invisible to CI before.

## Not in scope

- Not a replacement for periodic `/dogfood` runs — this is a narrow CI smoke test, not full golden-path coverage.
- Not a general CI infrastructure overhaul — add the smallest check that would have caught FRIC-007, matching how it's actually verified in that ticket's fix (`sol dev up` + `sol up` + one `curl`).
- Whoever picks this up should check whether existing CI runners have Docker/k3d available at all before designing the gating — if not, this may need a separate, opt-in workflow rather than a hook into the existing test suite.
