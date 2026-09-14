---
id: FEAT-066
type: feature
severity: medium
source: DEC-018, 2026-09-11 — the release record and its restoration
---

**Depends on:** BUG-026.

**Related:** DEC-018 (the decision this implements), FEAT-050 (digest-pinned artifacts), FEAT-065 (requested scope + resolved set in the plan), DEC-016, DEC-020.

Record every release immutably in the target's cluster, and make `sol rollback` restore a recorded boundary.

## Suggested order — do not start with the mutation

**Slice 1 — split out to FEAT-067 (2026-09-12):** writing the release record on every deploy, and adding `sol releases`. It was split into its own ticket so it could land read-only, with no mutation risk, and exercise the record shape against real deploys before this ticket's rollback depends on it. The record's requested scope and resolved set come from FEAT-065, which has landed.

**Slice 2:** the migration check and `sol rollback <release-id>` for the shapes whose mechanism is already native (rolling, canary, blue-green) — with the verification step. It restores from the release record, so it needs the complete record BUG-026 delivers.

**Slice 3 — split out to FEAT-072 (2026-09-14):** the lease and quiescence handling shared with deploy, function/recreate reconciliation, retention pruning.

## Work

*(The record itself and `sol releases` are FEAT-067. These bullets are the
remaining slices 2–3; rollback reads the record FEAT-067 writes.)*

- **`sol rollback <release-id>`**, plus `--commit` (ambiguous → list candidates and require a choice; always echo the resolution) and `--scope` as release *selection* only.
- **Migration boundary check:** refuse on a *contracting* migration between the target release and now, naming the release and the migration. No `--force`.
- **Verify structurally** after restoration (configuration, digests, scope membership), and skip verification where a GitOps controller owns the resources — reporting that rather than claiming a match.

*(Lease/quiescence and retention moved to FEAT-072.)*

## Acceptance criteria

- (Slice 1, now FEAT-067: every deploy writes a release record, `sol releases` shows it, and a release ConfigMap cannot be edited in place.)
- `sol rollback` restores the recorded boundary and refuses when a contracting migration blocks it.
- Rolling back a release whose `requested_scope` resolved to a subset restores exactly that subset, not today's membership of that scope.
- Verification reports structural equality where Sol is the mutator, and reports that verification is not applicable where a controller owns the resources.

## Carry-forward from FEAT-069 (2026-09-13)

**Rollback is a logical transition, not a pointer move.**

```text
rollback
  = restore the prior release content
    + make the current-release pointer agree with it

as one logical transition. Pointer-only rollback is invalid.
```

`sol-current-release` *reflects* the active release; it does not *cause* it.
Moving the pointer without restoring the workload desired state leaves the
pointer claiming `r_old` while the workloads still carry `r_new`'s manifests —
which is worse than no rollback, because the store now lies.

Do **not** claim Kubernetes-level transactional atomicity across workloads, the
release record and the pointer: a multi-object apply does not provide it. The
invariant to hold is narrower and achievable: **the pointer must not advance
independently of the desired release state.** How it is enforced is this ticket's
choice — ordered apply + verification, server-side apply, git-commit atomicity in
GitOps mode (where the content and the pointer travel in one commit, which is why
the pointer belongs in the emitted bundle), or an explicit protocol. State which,
and make inconsistent states detectable rather than silently reconciling them.
