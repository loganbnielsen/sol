---
id: INFRA-055
type: bug
severity: high
title: Write the release record without needing generic patch on ConfigMaps
source: audit finding FND-0014 — DEC-037
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0014-release-pruning-lists-configmaps-it-may-not-list.md`
**Decision:** `DEC-037`

## The defect

`Sol_cli_release_store.record` writes both release ConfigMaps through
`Sol_cli_kubectl.apply`. `kubectl apply` on an object that already exists degrades
to a **patch**, and the deploy identity's boundary-lease grant
(`platform_deploy_rbac.tf`, `sol_boundary_lease`) is `create` plus
`get`/`update`/`delete` — **no `patch`**. So:

- the first write of a given object succeeds (`create` is granted);
- every later write is refused:
  `error when patching "sol-release-current-pluto" … cannot patch resource "configmaps"`.

Live: the pointer still names `r-6d35ecdb68a52996` while the deploy was recording
`r-33d8e08d02d2a45c`.

## The FND-0011 pattern applies — checked, not assumed

FND-0011 was the same mechanism (apply→patch) resolved on the client side rather
than by widening the grant. The same narrower route exists here, and the two
questions below are the ones that decide whether it is safe.

**Mechanism.** `update` *is* granted, so the pointer can be written as an explicit
`get` + `replace` (RBAC `update`) instead of `apply` (RBAC `patch`). No grant change
is needed, and the deploy role does not acquire generic `patch` on ConfigMaps in
`default` — which is the verb that would let it rewrite any ConfigMap there,
including the boundary lease that serialises deploys.

**Concurrency — the part that had to be checked.** A read-then-write is a
read-modify-write, so it is only safe if something serialises it. It does:
`record_release_and_prune` is called **inside**
`Sol_cli_boundary_lease.with_boundary_lease` (`cmd_deploy.ml`, the apply path), with
`~holder:Deploy`, and the lease is renewed before each mutation. The lease is
acquired by `create` on a ConfigMap in `default` and renewed by `update`, so it is
a mutual-exclusion primitive over workspace mutation, and the lease's own verbs are
exactly the ones the grant already has.

Therefore the narrower mechanism is correct **provided the write stays inside the
lease**. Record that as a constraint, not a coincidence: if release recording is
ever moved outside `with_boundary_lease`, this mechanism acquires a lost-update
window and `apply`'s patch would have hidden it.

**Lifecycle.** The pointer's only writers are `record` (deploy/`sol up`) and
`move_pointer` (rollback, `cmd_rollback.ml:91`), so fixing `record` and routing
`move_pointer` through the same writer covers both. Handle three cases: pointer
absent → `create`; present → `replace` with the read object's `resourceVersion` so a
genuine concurrent change is a conflict rather than a silent overwrite; content
already identical → no write at all.

## Also fix the immutable record's re-write

The same trap sits one line earlier. The per-release ConfigMap is content-addressed,
so re-deploying identical content attempts to write an object that already exists —
a patch, refused. **After `INFRA-054` makes record failure fatal, that would fail
every repeated deploy of unchanged content.** So the same
exists-and-identical-is-ok logic must cover both objects, not just the pointer.

## Acceptance criteria

1. A record write needs only `create`, `get`, `update` on `configmaps` in
   `default` — no `patch`, and no widening of the grant. The guard in
   `internal/ci/` that pins the deploy role's verbs must still pass unchanged.
2. Re-recording an existing, identical release succeeds without writing (or writes
   idempotently), so repeated deploys of unchanged content do not fail.
3. An existing pointer with different content is updated, and the pointer afterwards
   names the release just applied.
4. Rollback's `move_pointer` uses the same writer.
5. A leave-a-comment note at the call site states the "must stay inside the
   boundary lease" constraint and why.
6. Live: a second and third `sol deploy` against the preserved Run 8 target succeed,
   and `sol-release-current-pluto` names the latest release.

## Out of scope

The prune's `list` (`INFRA-051`) — pruning stays best-effort per DEC-037. And
`INFRA-054`, which must land independently: the guarantee that a failed record fails
the deploy is what makes this defect visible rather than silent.

## Landed (2026-09-20)

DEC-037 implemented: `get`+`replace` (`create` when absent, no write when identical), needing no generic `patch`; rollback uses the same writer. Live-retested: the pointer advanced off the stale value.

Merged in #395; live-retested against the preserved Run 8 target. See
`internal/qualification/records/2026-09-20-run8-aws.md`.
