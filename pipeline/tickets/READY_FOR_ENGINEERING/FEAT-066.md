---
id: FEAT-066
type: feature
severity: medium
source: DEC-018, 2026-09-11 — the release record and its restoration
---

**Depends on:** None.

**Related:** DEC-018 (the decision this implements), FEAT-050 (digest-pinned artifacts), FEAT-065 (requested scope + resolved set in the plan), DEC-016, DEC-020.

Record every release immutably in the target's cluster, and make `sol rollback` restore a recorded boundary.

## Suggested order — do not start with the mutation

**Slice 1 — split out to FEAT-067 (2026-09-12):** writing the release record on every deploy, and adding `sol releases`. It was split into its own ticket so it could land read-only, with no mutation risk, and exercise the record shape against real deploys before this ticket's rollback depends on it. The record's requested scope and resolved set come from FEAT-065, which has landed.

**Slice 2:** the migration check and `sol rollback <release-id>` for the shapes whose mechanism is already native (rolling, canary, blue-green) — with the verification step.

**Slice 3:** the lease and quiescence handling shared with deploy, function/recreate reconciliation, retention pruning.

## Work

*(The record itself and `sol releases` are FEAT-067. These bullets are the
remaining slices 2–3; rollback reads the record FEAT-067 writes.)*

- **`sol rollback <release-id>`**, plus `--commit` (ambiguous → list candidates and require a choice; always echo the resolution) and `--scope` as release *selection* only.
- **Migrate before mutation:** abort an in-flight deploy, wait for quiescence, refuse if quiescence cannot be established. One lease per target/scope boundary, shared with deploy.
- **Migration boundary check:** refuse on a *contracting* migration between the target release and now, naming the release and the migration. No `--force`.
- **Verify structurally** after restoration (configuration, digests, scope membership), and skip verification where a GitOps controller owns the resources — reporting that rather than claiming a match.
- **Retention:** last 20 successful releases per target, configurable, current and previous never pruned.

## Acceptance criteria

- (Slice 1, now FEAT-067: every deploy writes a release record, `sol releases` shows it, and a release ConfigMap cannot be edited in place.)
- `sol rollback` restores the recorded boundary and refuses when it cannot establish quiescence or when a contracting migration blocks it.
- Rolling back a release whose `requested_scope` resolved to a subset restores exactly that subset, not today's membership of that scope.
- Verification reports structural equality where Sol is the mutator, and reports that verification is not applicable where a controller owns the resources.
- Retention prunes only successful releases beyond the window, and never the current or previous one.
