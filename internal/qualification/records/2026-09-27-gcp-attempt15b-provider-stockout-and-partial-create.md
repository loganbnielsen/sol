# GCP qualification Attempt 15b (2026-09-27) — provider stockout, and a partial create Sol cannot destroy

## Summary

| | |
|---|---|
| revision | `a1637841` (current `main`; `#591` an ancestor — confirmed before the run) |
| target | fresh `qual15b/gcp/us-central1`, cluster `sol-qual-gcp-15b`, fresh state prefix |
| result | **STOPPED at boundary 3** — the provider could not create the cluster |
| first blocker | **GCE zonal stockout** (provider-owned, transient) |
| last boundary crossed | **boundary 2: the Terraform plan succeeded**, and the cluster was Standard by construction (`remove_default_node_pool` accepted, no Autopilot request) — this is `#591` verified live |
| new finding | **`FND-0065`**: the supported destroy cannot converge a target whose creation the provider failed |
| billable residue | none, after an authorized emergency cleanup (recorded separately; not Sol destruction) |

## Boundaries

1. **Preflight — clean.** Fresh prefix matched no objects, no clusters, durables present and
   resolving, `disk-quota: PRESENT (SSD_TOTAL_GB limit=1000 usage=0 free=1000)`.
2. **Plan — succeeded.** The previous attempt's plan-time failure is gone; the cluster resource was
   accepted with no `enable_autopilot` attribute and `remove_default_node_pool = true`.
3. **Cloud apply — FAILED (375.3s).** `Error waiting for creating GKE cluster: Try a different
   location, or try again later: Google Compute Engine does not have enough resources available to
   fulfill the request`, against `google_container_cluster.main`. The cluster was left in `ERROR`.
4–12. **Not reached** (outputs/parser, substrate observation, quota policy, prerequisites, bindings,
   full apply, PVCs, readiness, `Ready`, Ready-state destruction).

## What the destroy did, and why that is the interesting part

Verbatim in `FND-0065`. In short: the recovery plan proposed to **Replace** the half-created
cluster, Sol's phased guard refused (destroy must not construct — correctly, and by design), the
destruction degraded, and it exited non-zero with the cluster standing. The harness refused to call
teardown verified and kept the target file, which is the behaviour it should have.

## Emergency cleanup (recorded separately, not Sol destruction)

Both conditions of the qualification policy were met — the supported path failed and billable
infrastructure remained — so the operator deleted, with `gcloud`:

- `sol-qual-gcp-15b` (GKE cluster in `ERROR`, billable);
- `sol-qual-gcp-15b-postgres` (Cloud SQL, created by the failed apply *before* the cluster failed,
  billable).

**No raw state surgery was performed.** The Terraform state still describes those resources — which
is exactly the gap `FND-0065` records.

Final independent verification: no clusters, no SQL, no disks, `SSD_TOTAL_GB 0/1000`, durable
prerequisites (`sol-qualification-tfstate`, `qual-gcp-sol-fab-dev`) intact. Non-billable litter
remains (one node subnet, one internal peering address, one empty Artifact Registry repository, one
service account, one custom role and its bindings).

## Process notes

- The harness stopped mid-capture when an operator polling call was interrupted; its teardown never
  ran, which is why an emergency path was needed at all.
- Two manual destroy attempts were wrong before the harness's own `destroy` phase was used: first
  from the repository root (`not inside a Sol workspace`), then from the workspace without the
  harness's variable flags (`No value for required variable`).

## What this run does not establish

Nothing is advanced: `PlatformInstalling → Ready`, the storage boundary, `FND-0061`'s binding
observation and Ready-state destruction are all unreached, and the binding capture that ran read an
`ERROR` cluster. It says nothing about AWS, interrupted destruction, stale-state recovery, Autopilot
support, regional node-pool HA, or other providers.
