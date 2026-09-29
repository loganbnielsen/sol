---
id: FND-0070
type: audit-finding
severity: high
source: qualification
---

# A failed apply leaves resources Terraform never adopted, and the destroy reports verified absence while they stand

## What happened

Attempt 25's `sol cloud apply` failed at the Cloud SQL instance — the provider timed out waiting for creation:

```text
│ Error: Error waiting for Create Instance:
│   with google_sql_database_instance.postgres,
```

The harness then ran the supported teardown. Sol reported:

```text
[terraform-destroy] ok (645.5s)
    residue Terraform does not own (controller load balancers, PVC volumes, abandoned peering): none found
Done. Destruction reached verified absence.
```

The provider says otherwise:

```text
$ gcloud sql instances list --project sol-qualification --format='value(name,state)'
sol-qual-gcp-25-postgres	RUNNABLE
```

and the harness's independent check agrees with the provider, not with Sol:

```text
  ✗ quota still exists (PRESENT) — non-zero usage
verify: resources remain
```

## Mechanism

The provider **created the instance anyway** and the create call still returned an error, so Terraform
recorded nothing in its state — the resource exists in GCP and is unknown to the state that the destroy
is driven by. Everything downstream then behaves consistently with that:

- `terraform destroy` is honest: it destroyed everything its state represented, including the network and
  the cluster, and reported success;
- the residue sweep found nothing, because on GCP it checks **one** class — the service-networking
  peering (`relinquished_residue_probes = ["google_service_networking_connection.sql", gcp_peering_probe]`) —
  while `aws_orphan_sweep` checks tag-derived load balancers and EBS volumes **and** has a gap path for a
  cluster name it cannot derive;
- the absence verdict is built from those two, so it concluded *verified absence*.

The consequence is exactly what the destruction contract forbids: **a claim of absence while a Sol-owned
resource stands**, and — worse — that resource is **unreachable by the supported destroy path**, because
the path acts on Terraform's state and the state does not know the resource exists. Attempt 25's SQL
instance is standing for that reason, and it also explains the 80 GiB `SSD_TOTAL_GB` reading that attempts
22 and 23 flagged: Cloud SQL storage counts against that quota.

## It has happened before

`sol-qual-gcp-15b` (an Artifact Registry repository, a reserved peering address and a provisioner service
account) is still in the project from an earlier attempt, and this is the most likely explanation for it
too. Both were reported rather than deleted; neither was created or left by the run that found it.

## Decision (2026-09-29): detect, refuse, name — then restore Terraform ownership

The operator decided: the immediate safety requirement is that such a resource is **PRESENT, not absent**,
and Sol must never report verified absence while it remains. Detect-and-refuse is not the terminal
behaviour: the long-term invariant is that every resource Sol causes Terraform to create stays
Terraform-owned or is deterministically recoverable into Terraform ownership, with Terraform remaining the
mutation authority and provider APIs the reality authority.

**Phase 1 (this work)** replaces the ad-hoc residue sweeps with a common absence contract behind two
provider inventories, so a discrepancy can no longer be reported as absence. See
`internal/qualification/records/2026-09-29-fnd0070-phase1-provider-inventory-and-live-regression.md`.

**Phase 2 (next)** restores Terraform ownership of an orphan through deterministic identity, and is
recorded with its evidence and constraints below.

## Earlier analysis: what is needed (a decision, not a mechanical fix)

**Detection is mechanical**: the GCP residue sweep should be brought up to the level the AWS sweep already
sets — name-addressed provider resources for the target's identity (the SQL instance named after the
cluster, the Artifact Registry repository, the reserved addresses, the service accounts and custom role,
the cluster itself), reported as residue when they exist and are not represented in state. That closes the
false claim.

**Reclamation is the decision.** A resource Terraform never adopted cannot be destroyed by the state-driven
path, so a supported command needs one of:

1. **Detect and refuse, report the orphan by name, and stop** — the destroy exits non-zero and names what
   stands, with reclamation left to the operator (safest, no new destructive authority);
2. **Adopt then destroy** — `terraform import` the named resource into the disposable root's state, then run
   the ordinary destroy against it (uses Terraform's own ownership, keeps one deletion path, but an import
   of a partially-created resource needs care);
3. **Reclaim by identity** — Sol deletes the named provider resource directly (most complete, but Sol gains
   provider-side deletion logic for resources it does not track, which the destroy design deliberately
   avoids today).

The finding is filed rather than fixed because option 3 in particular changes what a destroy is allowed to
do to something it never adopted, and because options 1 and 2 differ in who owns the risk of the delete.

## Evidence

| | |
|---|---|
| run | `/tmp/sol-gcp-qual-25` (attempt 25, revision `a30d54d4`) |
| Sol's claim | `Done. Destruction reached verified absence.` |
| provider | `sol-qual-gcp-25-postgres RUNNABLE` (still standing, deliberately) |
| independent check | `verify: resources remain` (`✗ quota still exists (PRESENT) — non-zero usage`) |
| state | the disposable cluster root's state is empty — the instance was never recorded |
