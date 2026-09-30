---
id: FND-0076
type: audit-finding
severity: low
source: AWS attempt 33 teardown — a warning that does not apply to destruction
---

**Depends on:** None.

**Related:** `cli/lib/cloud/sol_cli_aws_cluster.ml` (the de-escalation callback),
`internal/pipeline/audits/findings/FND-0071-…` (the boundary that check exists to protect).

# The destroy path runs the successor-authority check, which cannot hold while tearing down

## What happens

Teardown of the attempt-33 specimen printed this warning before destroying:

```
warning: the bootstrap access was removed but its effective removal could not be verified (the
bootstrap elevation was relinquished, but the durable cluster-access identity was not demonstrated
to hold the authority the lifecycle needs next: create namespaces is denied; create clusterroles is
denied; create storageclasses is denied). Proceeding: destroying the substrate removes the access
with it, and teardown is not blocked by a probe that can fail (ADR 0003 invariant 6).
```

The warning is produced by the check added for FND-0071's boundary: after the bootstrap window
closes, prove the durable cluster-access identity still holds what the *next lifecycle operation*
needs. On the apply path that is exactly right. On the **destroy** path the authority is expected
to be gone — the platform is being removed, so `create namespaces`, `create clusterroles` and
`create storageclasses` are all denied by design — and the probe therefore reports a failure every
time teardown runs.

The behaviour is safe (it warns and proceeds, per ADR 0003 invariant 6), but the message is
misleading in that context and it trains a reader to ignore a warning that on the apply path means
something real. Teardown also has a legitimate successor question of its own — whether the
*cluster-access identity can still reach the cluster to destroy it* — which is not what this probe
asks.

## Acceptance criteria

- The successor-authority probe is scoped to the operations where a successor is required, or
  reports destruction-appropriate capabilities on the destroy path.
- A teardown of a healthy target produces no "could not be verified" warning.
- Coverage: a destroy-path transition does not require namespace/clusterrole/storageclass
  creation, and an apply-path transition still fails when the successor lacks them — mutation
  tested, so scoping the probe cannot silently disable the FND-0071 guarantee.
