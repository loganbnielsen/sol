---
id: FND-0069
type: audit-finding
severity: high
source: GCP qualification Attempt 21 (2026-09-28), revision c6e16a69
---

# `sol cloud destroy` reports absence while a failed cluster still stands

**Depends on:** None.

**State:** `FIXED` — remediated offline with regression coverage and then exercised live against this
finding's own residue, which the corrected path converged with no manual action
(`internal/qualification/records/2026-09-28-fnd0069-live-regression-attempt21-residue.md`).

## Fix (2026-09-28)

**The absence claim is the library's verdict, not the reporter's aside.** `cmd_cloud_tf` printed
`destruction reached absence with N degraded preparation(s)` on the failure path as well as the success
path. It is replaced by `Sol_cli_cloud_destroy.completion_message`, so the claim exists once and only for
a destruction whose verification established absence; the failure path says destruction did not converge
and that nothing in the run establishes the resources are gone. Verified absence, remaining resources and
failed observation keep the distinctions the verification already modelled — violations versus unknowns,
with `UNKNOWN is not absence` — and an **inconclusive residue probe is now an unknown** rather than a
silent clean sweep (`classify` had been ignoring the sweep's `indeterminate` list while the same report
called it "not absence").

**A broken resource cannot make the substrate immortal.** The elevated bootstrap access is a
`ClusterRoleBinding` inside the cluster, so it is removed *with* the cluster; refusing to destroy the
substrate because it could not be unbound inverted the order and made a broken cluster permanent. A
cleanup failure is now a degradation — recorded, visible, and the substrate destroy proceeds, with the
absence check deciding. Two boundaries are unchanged: a *substrate destroy that fails* still fails the
run, and a *platform teardown that fails* still blocks, because the platform root can own resources
outside the cluster that do not disappear with it.

**`replace` is still refused**, per design: it is reconciliation toward a resource being present, and
during destruction the desired state is absence. The guard preparation's purpose — lowering deletion
protection before deletion — is belt-and-braces: the destroy passes `gke_deletion_protection=false` and
`sql_deletion_protection=false` itself (`destroy_guard_vars`), so a degraded guard preparation cannot
prevent deletion. No provider-side deletion logic was added and Terraform's graph is not duplicated: the
authority stays Terraform's state, the provider's residue sweep, and the final verdict.

**Regression coverage** (`cli/test/test_cloud_destroy.ml`): an unremovable binding does not immobilise
the substrate (destroyed, verified, exit 0, every fact preserved); a destroy that cannot converge exits
non-zero and claims no absence; residue the state does not own is not absence; an inconclusive probe is an
unknown, not a clean sweep. Three tests that encoded the old contract were re-based rather than deleted.

## Observed (GCP qualification Attempt 21)

Attempt 21's substrate never came up — GKE put the cluster in `ERROR` after 38 minutes
(`GCE_STOCKOUT` in `us-central1-f`; see the attempt's record for the provisioning half). The harness then
ran the supported teardown, as it does after any failure:

```text
teardown: sol cloud destroy qual21/gcp/us-central1
```

Sol's own narrative:

```text
warning: preparation: refused before apply: guard-preparation phase: replace on
         google_container_cluster.main (google_container_cluster) is not an action this phase permits
warning: a preparation degraded and destruction continued -- preparation: refused before apply:
         guard-preparation phase: replace on google_container_cluster.main ... is not an action this phase permits
warning: a preparation degraded and destruction continued -- the platform teardown was skipped because the
         bootstrap authority it needs could not be obtained (refused before apply: destroy-reconciliation phase:
         replace on google_container_cluster.main ... is not an action this phase permits)
warning: destruction reached absence with 2 degraded preparation(s)
error: refused before apply: bootstrap-access-removal phase: replace on google_container_cluster.main
       (google_container_cluster) is outside this phase's scope
```

and the provider, immediately afterwards:

```text
$ gcloud container clusters list --project sol-qualification --format='value(name,status)'
sol-qual-gcp-21	ERROR
$ gcloud compute regions describe us-central1 ... | jq '...SSD_TOTAL_GB...'
SSD: 200.0/1000.0
```

The harness's independent verification agreed with the provider, not with Sol:

```text
teardown NOT verified: resources remain — see .../inventory-*.tsv and inventory-*.log
KEEPING examples/pluto/sol/environments.local.yml — teardown was not verified, and destroy requires this file.
```

## Two defects, and why the second is the serious one

1. **A failed resource cannot be replaced by a preparation.** The destroy's preparations plan targeted
   applies; with the cluster in `ERROR`, Terraform proposes `replace` rather than a no-op update, and the
   phase policy refuses it (`Sol_cli_terraform_plan`, "is not an action this phase permits"). Sol degrades
   the preparation and continues — so the elevated-authority steps the teardown needs are never granted,
   and the platform teardown is skipped.

2. **The destroy still reported absence.** `destruction reached absence with 2 degraded preparation(s)` is
   printed while `google_container_cluster.main` is present and `ERROR`. A reader — or a script, or the
   qualification harness before its independent check — is told the substrate is gone when it is not. For a
   hosted product this is the worst shape a teardown bug can take: the operator believes the resources and
   the bill are gone.

The likely mechanism for (2) is worth checking first: an absence check that filters by expected status
(a cluster in `ERROR` is not `RUNNING`, so a status-scoped query returns nothing and reads as "absent").
The harness's `verify_absent` does not share that assumption — it lists by name and treats *presence* as
presence — which is why the two disagree.

## Impact

- A customer whose cluster fails to provision may be unable to destroy it through Sol **and** be told that
  it was destroyed. Attempt 21's cluster is still standing for exactly this reason: the supported path
  cannot converge a failed substrate, and the discipline forbids unsupported teardown, so the residue was
  left visible rather than quietly deleted.
- The qualification loop cannot proceed cleanly with residue standing: the next specimen's preflight sees
  a cluster that should not exist.

## What would close it

- **The absence claim must fail closed**: a resource the provider still lists — whatever its status — is
  not absent, and a degraded preparation must not be reported as a converged destruction.
- **A destroy must be able to remove a failed resource**: decide what a preparation phase may do when the
  resource it needs authority over is itself broken (permit the replace, or skip the preparation *and say
  the destruction is unverified*, rather than continuing as if it had succeeded).
- Regression coverage for both, in the shape the destroy-refusal tests already use.

## Evidence

Bundle `/tmp/sol-gcp-qual-21` (attempt identity, the GKE failure and its `GCE_STOCKOUT` condition, Sol's
destroy narrative verbatim, the harness's independent absence check, and the provider listing taken
afterwards).
