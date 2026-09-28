# GCP qualification Attempt 21 (2026-09-28) — a provider stockout, and a destroy that cannot converge it

## Summary

| | |
|---|---|
| revision | `c6e16a69` (the app phase with `POSTGRES_URL`, the operational step Attempt 20 was missing) |
| target | fresh `qual21/gcp/us-central1`, cluster `sol-qual-gcp-21`, 4 × e2-standard-4, `cluster_issuer: letsencrypt-staging` |
| result | **the substrate never came up**: GKE put the cluster in `ERROR` after 38 minutes — `GCE_STOCKOUT` in `us-central1-f` |
| why | the *transient* default node pool (`initial_node_count = 1`, `remove_default_node_pool = true`) is placed by GKE in a zone of its choosing; the cluster declared no `node_locations`. One zone's stockout failed the whole cluster before Sol's pool was reached |
| fixed | the cluster now declares its pool's single zone (`62ae4627`, PR #665) — a determinism fix, not a topology change: the pool was already single-zone |
| **also found** | **`sol cloud destroy` cannot converge a failed cluster, and reports absence while it stands** → `FND-0069`, high |
| residue | **sol-qual-gcp-21 stands in `ERROR`**; the supported destroy could not remove it and unsupported teardown is not permitted, so it was left visible rather than quietly deleted |
| the application row | not reached: the platform did not exist. One retry is needed once the residue is cleared |

## 1. Identity and what ran

| Field | Value |
|---|---|
| revision | `c6e16a69` |
| preflight | clean: no clusters, no SQL instances, `SSD_TOTAL_GB 0/1000` |
| substrate | `terraform-plan ok (3.2s)`; `terraform-apply **FAILED** (2299.0s)` |
| failure | `Error waiting for creating GKE cluster: … Not all instances running in IGM after 35m7.9s … [GCE_STOCKOUT]: Instance 'gke-sol-qual-gcp-21-default-pool-4662f275-zv5v' creation failed: The zone 'projects/sol-qualification/zones/us-central1-f' does not have enough resources available to fulfill the request.` |
| Kubeconfig waiter | `TIMEOUT after 1800s` (the cluster never reached `RUNNING`) |
| platform | never reached — no platform apply, no `Ready`, no application |
| evidence | `/tmp/sol-gcp-qual-21` (75 readiness samples, the platform-failure capture, both destroy attempts) |

This is a **provider capacity condition**, not a product or harness defect in itself — GCE had no
`e2-standard-4` capacity in one zone at that moment.

## 2. The part that is Sol's

The node pool Sol owns pins its zone (`node_locations = ["${var.region}-a"]`); the cluster declared none,
so GKE placed the **throwaway** default pool wherever it liked — here `us-central1-f` — and when that zone
was stocked out the default pool's failure took the cluster with it. The pool Sol actually runs on was
never created. `62ae4627` (PR #665) makes the cluster declare the same single zone as its pool, so both
land together and the topology is deterministic; `check_gcp_standard_substrate.py` now refuses a cluster
with no `node_locations` or one whose list differs from its pool's, with a mutation for the dropped list.

## 3. The part that matters more: destroy could not converge it, and said it had

The harness ran the supported teardown after the failure. Sol's destroy refused its own preparations —
Terraform proposed `replace` on the `ERROR` cluster and the phase policy permits no such action — degraded
them, skipped the platform teardown for want of bootstrap authority, and then reported:

```text
warning: destruction reached absence with 2 degraded preparation(s)
```

while the provider still listed the cluster:

```text
sol-qual-gcp-21	ERROR
SSD: 200.0/1000.0
```

The harness's independent check disagreed with Sol and kept the target file ("teardown was not verified:
resources remain"). That disagreement is the finding: `FND-0069` records both halves — a destroy that
cannot remove a failed resource, and a destroy that claims absence while the resource stands. For a hosted
product the second is the dangerous one: the operator believes the resources and their cost are gone.

**The residue is deliberately left standing.** Converging it is what Sol's destroy is for; the supported
path cannot, and using a direct provider delete would both hide the defect and step outside the discipline
that says teardown is the product's job. It is left visible for the operator, with the evidence above.

## 4. Where the application row stands

Not reached, and not for want of readiness: Attempt 20 already established the platform half of this
objective — the strengthened `Ready`, with the platform's declared certificates `True` at the moment the
lifecycle reported it. What remains unobserved is the application path itself (build → push → migrate →
`sol deploy` → transaction). It needs exactly one fresh specimen, once the residue is cleared and the
destroy path can converge a failed substrate.
