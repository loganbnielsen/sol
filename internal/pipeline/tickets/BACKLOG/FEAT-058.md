---
id: FEAT-058
type: feature
severity: low
source: review of FEAT-057 (same-cluster check) 2026-09-11 — it compares config names, not clusters
---

**Depends on:** FEAT-059.

**Related:** DEC-016, DEC-020, FEAT-057.

Downgraded from `READY_FOR_ENGINEERING` on 2026-09-11: DEC-020 removes the hidden input that made this urgent (an ambient `kubectl` context silently choosing the destination), which leaves this ticket as defense-in-depth against a different and rarer class — an *explicitly named* destination that resolves to an unexpected physical cluster. Kept because the analysis is sound and the trigger conditions below are foreseeable; not needed for DEC-020's invariant, and deliberately not built while nothing is live and the deployment contract is still being designed.

# Enforce environment isolation against the cluster itself, not the config

## What it would add

FEAT-057's check compares `cluster_id = (provider, region, cluster_name)` — three strings read from configuration. It is a good lint and it stays. What it cannot see: a destination that is named one thing and resolves to another.

- **Two kube-contexts aliasing one cluster.** `prod` and `prod-eu` pointing at the same API server.
- **A stale or re-spelled field.** A `region` never updated after a move, or a cluster renamed with only one target edited. These fields are *declared*, never verified, so staleness silently disables the comparison.
- **Same shape, different account.** Provider, region and name can all match across accounts.
- **A repointed context.** Prod's context edited to point at dev — the configuration was correct when written.

The root difficulty: **a name is not an identity.** What a name resolves to is a property of the credentials on the deploying machine, not of the file.

## Shape, if built

1. **A cluster-side environment marker.** `sol deploy` writes `sol.dev/environment: <env>` on the namespace it manages and refuses to apply when the cluster carries a *different* environment's marker. Absence means unclaimed, not conflicting — the first environment to deploy claims the namespace. Needs credentials only for the target cluster, cannot be aliased around because it travels with the cluster. Consistent with DEC-016: the environment may appear in a **label**, never in a name or an address.
2. **Record the resolved cluster identity per environment.** The `kube-system` namespace UID, or the context's server URL, stored alongside the environment's state on each successful deploy. Catches a repointed context, because it compares what actually happened rather than what the config intends — the same shift as pinning digests instead of tags.

Both are additive: no existing deployment needs re-creating, and a namespace gains its marker on its next deploy.

## Trigger conditions

Promote this out of backlog when any of these becomes true:

- **Sol Cloud owns credentials and cluster selection**, where a wrong lookup key is an ordinary bug rather than a user error, and where nobody is watching a terminal.
- A customer or operator is **deliberately running two environments on one cluster** and we need to refuse it structurally rather than by lint.
- Any observed instance of a destination resolving somewhere unexpected.
- Multiple contributors or CI jobs share one kubeconfig, where a repointed context becomes plausible.

## Acceptance criteria (when promoted)

- Deploying environment A into a cluster that has previously deployed environment B fails closed, without needing credentials for B.
- Two contexts aliasing one cluster are detected at deploy time, even when provider/region/name differ in configuration.
- The failure names both environments and the cluster, and says how to resolve it.
- The config-level lint remains, and its false positives are documented rather than silent.
