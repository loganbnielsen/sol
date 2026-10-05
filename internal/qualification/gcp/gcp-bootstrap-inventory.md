# GCP bootstrap inventory — historical snapshot

The read-only inventory in this document was taken on 2026-09-18. Its billing, API, bucket, service-account, region and implementation observations are historical and must not be used as current preflight results. The GCP harness writes `inventory-pre.tsv` and `inventory-post.tsv` for each run; those records, the current GCP matrix, and `internal/pipeline/audits/QUALIFICATION_STATUS.md` carry current qualification claims.

## Durable rules retained from the inventory

- Bootstrap may use the operator's user ADC. Routine Terraform impersonates the named provisioner service account with short-lived credentials; never create a long-lived service-account key.
- Project Owner does not establish billing-account, registrar/DNS-delegation or organization-policy authority. Probe those independently.
- The durable Terraform root owns the state bucket and qualification Cloud DNS zone. The zone is adopted by import when needed so parent delegation survives. Changing the durable-root region can replace the bucket; never silently accept that plan. A move also requires re-adopting the zone (DEC-043).
- Before mutation and after teardown, inventory the provider's resources. A Terraform exit status does not establish an `ABSENT` cost verdict.

The original inventory and chronological notes are preserved in [the dated record](../records/2026-09-18-gcp-bootstrap-inventory.md). This file is retained as a pointer because older run records link to it. The operative procedure is `internal/qualification/gcp/live-qual.sh`, with rows in `gcp-production-single-region-v1-matrix.md` and its TSV.
