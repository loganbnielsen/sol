# Alpha.7 cloud campaign — AWS and GCP attempts (2026-10-04)

Two specimens. **A** is the published `v0.1.0-alpha.7` release (archive sha256
`f7b34b0510d9fde9e364cb7aeeab770df4dbaccff3dfa15fd1b16bc6d3230d92`, runner
`ghcr.io/loganbnielsen/sol-migration-runner@sha256:65f74feb…`). **B** is locally patched and
**unpublished**: `v0.1.0-alpha.8.local`, built with `internal/tooling/scripts/build-release-bundle.sh`
from `ad253405` (`origin/main` at the time plus the absent-state patch), carrying A's runner digest.
AWS attempt 1 used A, AWS attempt 2 used B, and every GCP attempt used A.

Local patches in force, none merged: **P1** the absent-state fix in `cli/lib/cloud`, **P1a** its
first-run regression case, **P2** the GCP harness target no longer omits `app_db`/`events`. They are
filed as BUG-205 and INFRA-104.

## Attempts

| # | provider | target | specimen | outcome |
|---|---|---|---|---|
| 1 | AWS | `qualalpha7/aws/us-east-1` | A | `sol cloud plan` failed: `error: terraform state list failed with exit 1`, immediately after `[terraform-plan] ok`. Nothing created (BUG-205). |
| 2 | AWS | 〃 | B | Provisioned: cluster ACTIVE, RDS available, every platform namespace created. The platform apply then failed at `module.platform.helm_release.redpanda` (705.2s, `context deadline exceeded`). The retry resumed as `cluster-access` and was refused; destroy failed on RDS deletion protection, leaving the database, a VPC and a NAT gateway; cleaned up by hand. |
| 1 | GCP | `qualalpha7/gcp/us-central1` | A | `service "orders_svc" uses undeclared resource "app_db"` — the harness's own target omitted the resources its enabled services use (P2, INFRA-104). |
| 2 | GCP | 〃 | A | `"account_id" ("sol-qual-gcp-alpha7-provisioner") doesn't match regexp …` — GCP caps derived service-account ids at 30 characters (BUG-208). Renamed to `sol-qual-gcp-a7`. |
| 3 | GCP | 〃 | A | GKE creation: `does not have enough resources available to fulfill request: us-central1` (provider capacity). |
| 3b | GCP | `…/us-east1` | A | The durable root refused: `google_storage_bucket.state must be replaced`, `location = "US-CENTRAL1" -> "US-EAST1" # forces replacement`. The guard is right — the region is a durable-root input, so a move means a new bucket and re-adopting the zone. Reverted. |
| 4 | GCP | `us-central1` | A | GKE succeeded; `Error waiting for Create Instance:` with an empty body on `google_sql_database_instance.postgres` after 736s. |
| 5 | GCP | 〃 | A | **Provisioned**: GKE `RUNNING`, Cloud SQL `RUNNABLE`, `[terraform-apply] ok (716.1s)`. The platform apply then failed at the same resource as AWS — `helm_release.redpanda`, 689.9s, `context deadline exceeded` — followed by `provisioner-bootstrap-access-remove ok (5.4s)`. |

## What the paired failure establishes

AWS attempt 2 and GCP attempt 5 ended at the same resource, with the same message, roughly 700
seconds into a cold cluster's platform install (705.2s and 689.9s). The documented prerequisite for
that chart is operator-supplied: `docs/deployment/production-bootstrap.md` §1 creates the
`redpanda-users` Secret before the platform apply and states the consequence — "when that Secret is
absent the Redpanda release cannot start". No code path creates it, neither harness creates it
(INFRA-108), and neither attempt created it by hand. BUG-206 owns the mechanism and the diagnosis
fix; BUG-207 owns resumption after a failed install.

## Findings and where each went

`A1`→BUG-205 · `A2`→BUG-206 · `A3`→BUG-207 · `A4`+`H1`→BUG-209 · `A5`→no defect (DEC-034/DEC-039
give cluster-access platform administration) · `A6`→no defect · `A7`→BUG-208 · `A8`→provider
capacity, no ticket · `H2`→INFRA-103 · `H3`+`Q2`+`Q3`→INFRA-104 · `H4`→INFRA-105 · `H5`→INFRA-106 ·
`Q1`+evidence contamination→INFRA-107 · harness prerequisites→INFRA-108.

## Cleanup

AWS: after the failed destroy, the database was removed by hand
(`modify-db-instance --no-deletion-protection`, then `delete-db-instance --skip-final-snapshot
--delete-automated-backups`); a second destroy pass removed the VPC and the NAT gateway; an
independent sweep found no clusters, instances, volumes, addresses, load balancers, live NAT gateways
or ECR repositories. GCP: the harness's own post-inventory read `teardown verified: absent` on every
attempt, and an independent sweep agreed. Both durable roots — the state buckets, the GCP zone, the
AWS roles — were untouched.

## What this record does not establish

No alpha row is qualified. No provider reached the end of the platform install, so the `platform`,
`app`, `destroy`-as-a-run and `verify` stages did not run at all. The 700-second deadline's first
failing pod/hook condition was not captured; BUG-206 owns reproducing it from a fixture. The AWS
destroy's deletion-protection failure is documented by BUG-209, not qualified here.

## The failed-install retry, verbatim (AWS attempt 2)

The retry was the harness re-running `sol cloud apply` for `qualalpha7/aws/us-east-1`. Sol resumed
the platform apply as `sol-qual5-cluster-access` and was refused:

```
Error: roles.rbac.authorization.k8s.io "sol-boundary-lease" is forbidden: User
"arn:aws:sts::123456789012:assumed-role/sol-qual5-cluster-access/EKSGetTokenAuth" cannot get
resource "roles" in API group "rbac.authorization.k8s.io" in the namespace "default"
Error: configmaps "sol-platform-network" is forbidden: … in the namespace "kube-system"
```

The one manual re-acquisition attempted — `terraform apply -var=provisioner_bootstrap_admin=true`
against the saved cluster root, mirroring the form the GCP records show Sol planning — changed
nothing observable: `aws eks list-access-entries --cluster-name sol-qual-alpha7` afterwards listed
only `cluster-access`, `deploy`, `operator`, the node role and the EKS service role (no entry for
`sol-qual5-provisioner`), and a kubeconfig built from the provisioner role answered `Unauthorized`.
BUG-207 owns tracing that path; the point here is that the temporary window did not survive the
failure and nothing in the retry reacquired it.
