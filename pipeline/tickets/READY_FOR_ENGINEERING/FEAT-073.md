---
id: FEAT-073
type: feature
severity: low
source: split from FEAT-066, 2026-09-14 — release selection for rollback
---

**Depends on:** FEAT-066.

**Related:** FEAT-066 (slice 2, which ships `sol rollback <release-id>` for an
exact id only), FEAT-070 (deployment events, the provenance join key this
would resolve from).

`sol rollback --commit <sha>` and `--scope` as release *selection*, split out
of FEAT-066's slice 2 so that slice could ship with the exact-release-id path
only.

## Why this was split out (2026-09-14)

FEAT-066's ticket body listed `--commit` (ambiguous → list candidates and
require a choice; always echo the resolution) and `--scope` as release
*selection* alongside the plain `<release-id>` form. Implementing `--commit`
means resolving a git commit SHA to one or more release ids — a *reverse
lookup from provenance to release identity* — which is a different kind of
operation from restoring an already-identified release, and the only existing
place commit provenance is recorded is the FEAT-070 deployment-event Loki log
line, which is telemetry, not an authoritative store.

Decision (recorded during FEAT-066 slice 2, per user direction): don't make
Loki authoritative for rollback selection, and don't bolt a Loki query client
onto FEAT-066 just to support a convenience selector. Ship the authoritative
path (`sol rollback <release-id>`) first; this ticket resolves `--commit`
against deployment/release provenance if that can be made to answer the
question, not against Loki by default.

## Work

- **`--commit <sha>`**: resolve to the release id(s) produced by a deploy at
  that commit. If more than one release matches (e.g. the same commit deployed
  to more than one target, or two deploys of identical content), list the
  candidates and require an explicit choice — never guess. Always echo which
  release id was resolved, even in the unambiguous case, so the operator can
  confirm before anything mutates.
- **`--scope DOMAIN[/UNIT]`** as release *selection* only: when combined with
  `--commit`, narrows which of that commit's releases to resolve (e.g. the
  same commit deployed both `payments` and the whole workspace as two separate
  releases). It must never mean "restore this domain out of a larger release"
  — a release's `workloads` list is restored whole, per FEAT-066's own
  release-record design; `--scope` only helps pick *which* release id.
- Investigate whether deployment/release provenance already recorded in the
  cluster (or addable without inventing a new Loki-backed query surface) can
  answer "which release id(s) came from commit X" authoritatively. If not,
  this ticket should say so explicitly and either scope down to what's
  answerable, or make the case for why a provenance store change is warranted
  — not silently reach for Loki as a stand-in authority.

## Acceptance criteria

- `sol rollback --commit <sha>` resolves unambiguously or lists candidates and
  refuses to guess.
- The resolved release id is always echoed before rollback proceeds.
- `--scope` narrows commit-based candidate resolution only; it never produces
  partial-apply semantics against a release's recorded workload set.
- The resolution mechanism is authoritative (not telemetry-backed by default);
  if no authoritative source exists yet, the ticket documents the gap rather
  than papering over it with a Loki query.
