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

## Implementation decision (2026-09-14, kickoff)

**Enforcement: ordered apply + verification, with inconsistency made detectable.**

1. Restore first: re-render the recorded release's manifests and apply them.
2. Only then move the pointer to that release.
3. Verify: the workloads Sol just applied carry the restored `release` label, and
   the pointer names the same release. If either disagrees, fail loudly and
   report the mismatch instead of re-applying or "fixing" it.

This is exactly the narrow invariant the ticket allows, not atomicity. In GitOps
mode the second step is free — the content and the pointer travel in one emitted
commit — and the same verification runs against the bundle.

Restoration source: the release record, now complete (BUG-026). `sol rollback
<release-id>` renders from the record's workload content; it does not use
`kubectl rollout undo`, which cannot restore config, volumes or ingress.
`--scope` is release *selection* only; `--commit` resolves an ambiguous release
by listing candidates.

**Order (a refused rollback must leave the cluster untouched).**

```
resolve target release
  → load + validate record
  → migration boundary check
  → reconstruct
  → render
  → apply
  → move pointer
  → verify
```

The migration check runs before any mutation and, where the information is
already available, before expensive apply preparation.

**Reconstruction is a historical decode, not a planner (red line).** It may
validate and decode recorded facts, but it must not resolve new release-defining
facts. Leaf helpers (`k8s_name_result`, `namespace_result`, `service_url`,
`cpu/memory_quantity_of_string`, the canonical enum decoders) are fine because
they are pure functions of recorded facts; anything that reads the workspace,
`sol.toml`/`sol.yml`, the environment, or discovery is not. In particular
`called_by` is a pure derivation of the record's own recorded `calls` — never
`recorded calls + today's discovery`.

**Verification reports its two failures independently** — `workload state
mismatch` and `pointer mismatch` — rather than collapsing them into one
"verification failed", because one passing and the other failing is operationally
meaningful evidence. The equivalence test
`render(original plan) == render(reconstructed record)` is the load-bearing
guardrail and starts as byte equality, since the renderer is already canonical.

### Finding (2026-09-14): `called_by`'s `env_var` is the caller's, not the edge's

`called_by` is derived from the release record's call graph, but its `env_var` is
computed from the **caller's** source name (`call_env_var caller.source_name`),
not copied from the stored forward-call edge (whose `env_var` is
`call_env_var target.name`). Reconstruction must therefore reuse the same pure
`call_env_var` helper as forward planning; reusing the stored edge env var would
preserve most of the graph while silently changing NetworkPolicy output — a
"passes most tests" failure mode.

`call_env_var` is a deterministic naming function over already-resolved names, so
it follows `service_url` out of the planner into a shared naming/domain module
rather than being exported as a planner-private helper. No new persisted field
is needed: the record already carries the whole call graph, so BUG-026 is not
missing a fact here.

### Reconstruction signature and the test trio

```ocaml
val service_specs_of_release : Sol_cli_release.t -> (service_spec list, string) result
```

No workspace/config/env parameters: the absence is the red line made structural.
Decode failures name the release, the workload and the offending fact (e.g.
`cannot reconstruct release r-X: workload payments has invalid progressive
delivery "canary:..."`), so an operator can tell a corrupt historical artifact
from a cluster refusing a valid restoration.

1. **Identity equivalence** — record → reconstruct → canonical projection →
   same `release_id`.
2. **Render equivalence** — plan → record → reconstruct → render is byte-equal to
   the original render, over the full manifest-affecting surface (rollout/canary,
   volumes/access modes, calls/`called_by`, ingress, config, secret references).
3. **Failure semantics** — a missing or invalid release-defining fact returns a
   named `Error` before any render or mutation, including one case that is valid
   JSON but semantically invalid (an unknown rollout encoding), proving
   fail-closed lives in the domain decoder and not only in JSON parsing.
