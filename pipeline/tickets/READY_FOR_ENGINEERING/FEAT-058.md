---
id: FEAT-058
type: feature
severity: high
source: review of FEAT-057 (same-cluster check) 2026-09-11 — it compares config names, not clusters
---

**Depends on:** DEC-016 (environments are targets), FEAT-057 (the config-level check it replaces or supplements).

Enforce environment isolation against **the cluster itself**, not against three strings in the target configuration.

## Why the rule exists at all

DEC-016 deliberately keeps environment identity **out of names**: namespaces, service names and injected internal URLs are identical in every environment, because that is what makes the same manifests promote unchanged. If dev and prod pointed at one cluster, that design stops being an optimisation and becomes a hazard:

- **A dev deploy would silently overwrite production.** Namespaces are derived from workspace and domain, not environment, so dev's `acme-payments/charge-svc` and prod's are the *same object*. The manifests are indistinguishable by construction, so `sol deploy --env dev` against prod's cluster replaces the running production workload — an outage caused by a routine command, with no diff to warn anyone.
- **`SOL_ENV` on the surviving pods would be whichever deployed last**, so application code that refuses destructive operations outside production would believe it was in production while running dev's build.
- **Observability would merge two environments** under one label set, and the config hash would flap as each environment rewrote the other's ConfigMap.

So the bargain is: *names stay environment-agnostic, therefore clusters must be separate.* The check is the second half of that bargain. Today it enforces the first half's precondition with strings.

## The gap

`validate_no_same_cluster` compares `cluster_id = (provider, region, cluster_name)` — all three read from configuration. Nothing consults the cluster.

**False negatives (the dangerous direction)** — one cluster, configured under names that differ, so the check passes:

- **Two kube-contexts aliasing one cluster.** `prod` and `prod-eu` in one kubeconfig pointing at the same API server. Common the moment contexts are named by convention rather than by cluster.
- **A stale or re-spelled field.** One environment's `region` was never updated after a move, or a cluster was renamed and only one target was edited. Since `provider`/`region` are *declared*, not verified, a stale value silently disables the comparison.
- **Two accounts, same shape.** Provider, region and cluster name can all match across accounts, where the tuple cannot tell them apart.

**False positives (annoying, safe)** — same cluster *name* in two genuinely different accounts: rejected, even though it is legitimate. The existing `test_same_cluster_name_different_region_succeeds` guards one such case; accounts are not represented in the tuple at all.

The root difficulty: **a name is not an identity.** What a cluster name resolves to is a property of the credentials on the deploying machine, not of the config file, so no amount of file inspection can close this. It becomes more dangerous, not less, once the hosted platform drives deploys — Sol holds many contexts, and a mismatch there overwrites a customer's production.

## Recommended shape

Layered, cheapest first, with only the middle layer being true enforcement:

1. **Keep the config check as a lint.** It catches the obvious mistake before anything is applied, and its message is good.
2. **A cluster-side environment marker — the real enforcement.** `sol deploy` writes `sol.dev/environment: <env>` on the namespace it manages, and refuses to apply when the cluster already carries a *different* environment's marker. This needs credentials only for the target cluster (no cross-environment access), cannot be aliased around because it travels with the cluster, and fails at the exact moment the accident would occur. It is also consistent with DEC-016: the environment may appear in a **label**; what it may not appear in is a name or an address.
3. **Record the resolved cluster identity per environment.** After a successful deploy, store the cluster's own identifier — the `kube-system` namespace UID, or the context's server URL — alongside the environment's state. Later deploys compare the cluster in hand against the identifiers recorded for the workspace's other environments. This is the only layer that catches a *repointed context* (prod's context edited to point at dev), because it compares what actually happened rather than what the config intends — the same shift as pinning digests instead of tags.

## Acceptance criteria

- Deploying environment A into a cluster that has previously deployed environment B fails closed, without needing credentials for B.
- Two kube-contexts aliasing one cluster are detected, at deploy time, even when provider/region/name all differ in configuration.
- The failure names both environments and the cluster, and says how to resolve it (a different target, or an explicit operator override).
- The config-level lint remains, and its false positives are documented rather than silent.

## Notes

Out of scope for REFAC-082, which consolidated the traversal underneath the existing check; this is about what the check compares, not how the files are walked.
