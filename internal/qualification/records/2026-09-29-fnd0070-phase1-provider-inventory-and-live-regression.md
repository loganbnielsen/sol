# FND-0070 Phase 1 — independent provider inventory, and the live regression on Attempt 25

## Summary

| | |
|---|---|
| revision | `a30d54d4` + this change |
| change | one common absence contract (`Sol_cli_absence`) behind two provider inventories (`Sol_cli_gcp_absence`, `Sol_cli_aws_absence`), replacing the ad-hoc residue sweeps |
| invariant | Sol may report verified absence only after independent provider observation establishes that no resource attributable to the target remains across the classes the lifecycle can create; Terraform's empty state is necessary evidence and never sufficient |
| live regression | `sol-qual-gcp-25-postgres` — **PRESENT**, attributed by name, absence refused, named for recovery, **not deleted** |

## The contract

`Sol_cli_absence` carries, for every observation: the resource class, the identity, **why a found
resource is attributable to this target**, and the command that established it. Five outcomes, three of
which decide the verdict:

| outcome | meaning | effect on the claim |
|---|---|---|
| `Absent` | the provider was observed and holds no such resource | permits it |
| `Present` | a resource attributable to this target exists | **refuses it**, and names it |
| `Unobservable` | the observation did not run or errored | **refuses it**, and names what did not run |
| `External` | present, but durable/external by contract (state bucket, delegation zone) | not residue |
| `Not_attributable` | the class cannot be attributed to a target at all | reported, never counted |

`Present` outranks `Unobservable` in the ordering, so a found resource is always reported first; both
refuse the claim, so neither can be read as absence. The report is printed on every destroy, whether or
not anything is found — *"the verifier should be able to explain what it checked and why a discovered
resource is attributable to this target"*.

## Coverage

**GCP (16 classes)**: GKE cluster, node pool, VPC network, subnetwork, Cloud Router, Cloud NAT, Cloud SQL
instance, reserved global address, service-networking peering connection, Artifact Registry repository,
service account, custom role, storage bucket, persistent disk, firewall rule, forwarding rule — every one
attributed by a stated rule (the target's own cluster name, or the target's own VPC for what GKE names
itself), and every class the cluster root or the shared platform module can create for a target is present.

**AWS (15 classes)**: EKS cluster, node group, RDS instance, RDS subnet group, security group, VPC,
subnet, IAM role, IAM policy, S3 bucket, CloudWatch dashboard, EKS control-plane log group, load balancer,
EBS volume, ECR repository — the last attributed by the target's own declared registry path, and the
tag-derived classes by `kubernetes.io/cluster/<name>`. Not exercised live: **no AWS run was performed and
no AWS qualification is claimed.**

Two defects were found by *running* the inventory rather than reading it: `gcloud compute subnetworks` is
not a command (the correct form is `compute networks subnets list`, now fixed, and the fixture's fake
`gcloud` was silently accepting it), and AWS reports a destroyed RDS instance as a **not-found error**
rather than an empty list, which read as UNKNOWN until not-found was recognised as absent.

## The live regression (Attempt 25)

```
PRESENT: Cloud SQL instance sol-qual-gcp-25-postgres: sol-qual-gcp-25-postgres (the target's own cluster
  name: every resource the target's roots create carries it … so sol-qual-gcp-25 is that name;
  checked with: gcloud --project sol-qualification sql instances list --format value(name))
error: Destruction did not converge: the destruction postcondition is violated: Cloud SQL instance
  sol-qual-gcp-25-postgres … is present after destroy …
```

- Terraform state does not own it (the disposable root's state is empty; the destroy's own evidence says
  so);
- the independent inventory finds it, and no `reached verified absence` appears anywhere in the run;
- attribution is unambiguous and printed;
- **the resource was not touched**: it is still `RUNNABLE`, as `provider-after.txt` records.

## `sol-qual-gcp-15b`, established rather than assumed

Run with the inventory's own commands for the 15b identity:

| class | found | attribution | ownership kind |
|---|---|---|---|
| VPC network | `sol-qual-gcp-15b` | named after the cluster | directly Terraform-managed |
| subnetwork | `sol-qual-gcp-15b-nodes` | named after the cluster | directly Terraform-managed |
| reserved address | `sol-qual-gcp-15b-sql-peering` (RESERVED) | named after the cluster | directly Terraform-managed |
| Artifact Registry repository | `sol-qual-gcp-15b` | named after the cluster | directly Terraform-managed |
| service account | `sol-qual-gcp-15b-provisioner@…` | named after the cluster | directly Terraform-managed |
| custom role | `projects/sol-qualification/roles/sol_sol_qual_gcp_15b_cluster_access` | `sol_<cluster>_…` | directly Terraform-managed |
| GKE cluster, Cloud SQL, buckets, disks | **none** | — | — |

So 15b is **six directly Terraform-managed resources**, not a mixed bag of residue — and the same
mechanism applies to it as to Attempt 25's instance. The default compute service account
(`819835583654-compute@developer…`) is present in the project and was **not** attributed to the target,
which is the attribution rules behaving as intended rather than over-reaching.

## Test coverage

- `cli/test/test_cloud_destroy.exe`: **45 tests**, six new ones over the contract — an empty inventory
  permits the claim; a present resource refuses it and names it; an unobservable class refuses it;
  `Present` outranks `Unobservable`; an `External` resource is not residue; the report explains
  attribution.
- `internal/ci/test_cloud_lifecycle_offline.sh`: two new scenarios — an orphaned Cloud SQL instance
  (emulating Attempt 25) is reported PRESENT, named, attributed, and the destroy exits non-zero with
  `Destruction did not converge` and no verified-absence claim; and the AWS EBS-class residue is reported
  the same way, naming `vol-residual`.
- The historical REFAC-093/REFAC-094 assertions were **narrowed, not deleted**: they still forbid
  re-querying a managed resource *by identity*, and no longer forbid the deliberate class-level
  observation Phase 1 requires.

## Not in this change

Ownership recovery (restoring Terraform ownership of a resource the provider created but the state never
adopted) is Phase 2 and is **not** implemented here: this change only makes the discrepancy impossible to
report as absence.
