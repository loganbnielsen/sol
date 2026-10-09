# Resource ownership

**Audience:** Contributors changing anything that removes a resource.
**Scope:** What counts as proof that Sol owns a resource, per ownership domain, and where each rule is enforced.

---

## The rule

Sol removes only what it can prove it owns. Ownership is never inferred from a
declaration, a label, a name, a namespace, or a creation time: those say that
*something claims* a resource, not that *this object is the one Sol created*.
Each domain has exactly one proof, and the proofs are not interchangeable.

| Domain | Proof of ownership | Enforced by |
|---|---|---|
| Kubernetes workload objects | the live object's `metadata.uid` equals the UID Sol captured when it applied that object | `#1304` milestone 2 — capture at apply, plan deltas, removal enforcement, guard; `#1305` consumes it for whole-target deploy and carries the `requested_scope` invariant — **in progress** |
| Cloud/Terraform resources | exact attribution inside ADR 0005's contract boundary | `Sol_cli_ownership_reconciliation`; `#1119` |
| Detach (authority handoff) | revocation of Sol's target-scoped execution principals | ADR 0006 |

## Kubernetes workload ownership

The rule, in four parts:

- **Capture at apply.** Applying an object records its `metadata.uid` next to its
  identity (kind, namespace, name).
- **Exact match to remove.** Sol may remove an object only while the live object's
  `metadata.uid` is exactly the recorded UID. Kubernetes assigns a fresh UID when
  an object is deleted and recreated, so an equal UID means this is still the
  object Sol created; a different UID means something else now occupies that name.
- **Absent evidence fails closed.** An object with no recorded UID — a record
  written before UID capture, or an object another path created — is not removed.
  It is adopted explicitly, or left alone.
- **Unobservable fails closed.** If the live object cannot be read (cluster
  unreachable, credentials denied, the kind not served), ownership is unknown.
  Sol removes nothing on that basis and says what it could not observe. There is
  no cluster-wide, name-based, or selector-based fallback.

### What is not ownership evidence

Declarations in `sol.yml` / `sol.toml` or `sol/environments.yml`; labels and
annotations of any kind (`app.kubernetes.io/*`, `sol/*`, a release label, a
`workspace` label on the pod template); name prefixes or suffixes; namespace
membership; creation order; and the absence of a competing declaration. Each may
select *what to look at*. None may authorize a removal, and a selector is the
weakest of all: it admits whatever matches at delete time, including objects
created after the read that decided to delete.

### Runtime enforcement

Two runtime paths remove Kubernetes workloads. Both require the recorded UID
match, decided by `Sol_cli_workload_ownership.owns`; the `workspace`/`release`
labels only select which objects to look at:

- `Sol_cli_rollback.prune_workloads` — a surplus workload is deleted only while
  its live UID equals the UID the superseded release recorded. An auxiliary the
  workload realizes (ServiceAccount, ConfigMap `-env`, NetworkPolicy, Service,
  Ingress, PodDisruptionBudget, a Rollout's `-active`/`-preview` names) follows
  the owning workload's match — the workload is the unit of ownership; a
  referenced PersistentVolumeClaim is never deleted.
- `Sol_cli_workload_scope` (used by cloud destroy to release workloads) — objects
  listed by the pod-template `workspace` label are released only on the same
  exact match.

An object Sol cannot match — a record written before UID capture, a different
UID, an absent object, or an unobservable one — is retained and reported for
explicit adoption. The executable guard proving declarations and labels alone
cannot authorize a deletion lands with the same milestone (`#1304`).

Terraform-declared Kubernetes objects (the platform module) have a **separate**
rule already enforced in CI: one object, one Terraform owner —
`internal/ci/check_kubernetes_object_ownership.py` fails two resources that
resolve to one Kubernetes object. That is cloud/Terraform attribution, not the
runtime UID proof, and neither substitutes for the other.

## Cloud/Terraform resource ownership

Terraform state attributes a resource to the root that declares it, inside the
boundary ADR 0005 defines. Recovery and adoption are explicit; Sol does not guess
that an existing provider resource is its own. See
[`adr/0005-sol-owns-only-its-contract-boundary.md`](adr/0005-sol-owns-only-its-contract-boundary.md)
and `#1119`.

## Detach

Detach is not an ownership claim about resources. It revokes Sol's target-scoped
cloud execution principals and works under ADR 0006's enforceable contract
(assume-only routine credentials, independently revocable provider and backend
identities, Kubernetes access revoked, state transferred under lock, and a
standalone plan showing no unintended change).
