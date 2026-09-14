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

## Completion notes

- **The investigative question resolves favorably: an authoritative source
  already exists, no scope-down or provenance-store change needed.**
  `Sol_cli_deployment.t` (FEAT-070's deployment-event record,
  `cli/sol/lib/sol_cli_deployment.ml`) already carries both `git_commit` and
  `release_id` on one record, persisted as an immutable ConfigMap
  (`Sol_cli_deployment_store`, kubectl-backed) — not the Loki deploy marker,
  which only ever carries the id as a join key for telemetry. The "Why this
  was split out" framing assumed the Loki marker was the only place commit
  provenance lived; the deployment-event record itself already answers the
  question directly.
- Implementation: `Sol_cli_rollback.resolve_commit` (new, pure, unit-tested)
  takes the full list of a workspace's deployment events plus `~commit`,
  `?scope`, `~target`, and returns `Commit_resolved`/`Commit_ambiguous`/
  `Commit_no_match`/`Commit_invalid`. It filters to `Applied` outcomes only
  (an `Apply_failed` attempt's `release_id` was never actually recorded —
  FEAT-072 writes release records only on a successful apply, so resolving to
  one would walk straight into a "release not found" this can refuse up
  front instead), matching `target` exactly and `--scope` (parsed via the
  existing `Sol_cli_deployment_scope.parse_request`/`request_to_string`, so
  it shares vocabulary with what a deploy actually recorded as
  `requested_scope`) when given, then dedups by `release_id` — repeated
  deploys of the same commit to the same release are one candidate, not a
  false ambiguity.
- `commit_matches` does a case-insensitive, either-direction prefix match
  (`git_commit` is stored as `git rev-parse --short HEAD`'s short form, so a
  user-supplied full sha must resolve it, and vice versa); empty on either
  side never matches, so an event recorded outside a git checkout
  (`git_commit = ""`) can't accidentally match every query.
- `cmd_rollback.ml`: `RELEASE_ID` is now optional (was `required`); new
  `--commit`/`--scope` flags. Exactly one of `RELEASE_ID`/`--commit` is
  required; `--scope` without `--commit` is refused explicitly rather than
  silently ignored. The resolved release id is printed
  (`commit_resolution_to_string`) before `run_locked` proceeds, in addition
  to `run_locked`'s own existing "Rolling back ... to release ..." line — two
  confirmations for the `--commit` path, matching "always echoed before
  anything mutates."
- `target` for filtering: the raw `--target ENV/PROVIDER/REGION` string for
  the top-level `sol rollback` form (the same string `cmd_deploy.ml` records
  on the deployment event), or the literal `"local"` for `sol local
  rollback` (matching `cmd_up.ml`'s convention for local `sol up`).
- Tests: `cli/sol/test/test_rollback.ml`, new `commit_release_selection`
  group (15 cases) — `commit_matches` (exact/full-resolves-short/
  short-resolves-full/case-insensitive/mismatch/empty-never-matches) and
  `resolve_commit` (no match, unambiguous, ambiguous lists both candidates,
  repeated deploys dedup, `--scope` narrows, wrong target excluded,
  `Apply_failed` excluded, invalid `--scope`, empty `--commit`).
- Doc: `docs/architecture/devops-pipeline.md`'s `sol rollback` section
  updated — was stale the moment `RELEASE_ID` stopped being strictly
  required.
- No demo/example update: this extends an existing CLI command's flags, not
  a new primitive, `sol.toml` field, or generated manifest.
