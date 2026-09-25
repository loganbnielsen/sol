# FND-0057 — On GCP, a `destroy_retention: none` destroy leaves the observability buckets' contents soft-deleted and billed for 7 days

- **Classification:** `VERIFIED_DEFECT` (static: configuration read against the provider's
  documented default), against DEC-033 (`none` means zero residual billable artifacts) and
  ADR 0004's retention postcondition
- **State:** `OPEN`
- **First identified:** 2026-09-24, during DEC-045's destruction-authority due diligence
- **Provider:** GCP (Cloud Storage)
- **Derived ticket:** `INFRA-077`
- **Evidence class:** `STATIC`. Not observed live: no GCP attempt has run with
  `enable_durable_observability`.

## What is established

1. `google_storage_bucket.loki` and `google_storage_bucket.thanos` (`cli/platform/infra/gcp/main.tf`,
   both `count = var.enable_durable_observability ? 1 : 0`, `force_destroy = true`) declare no
   `soft_delete_policy`, so the Cloud Storage default applies:
   `rg -n soft_delete cli/platform/infra` finds nothing.
2. Google's documentation (<https://docs.cloud.google.com/storage/docs/soft-delete>, read 2026-09-24):
   - *"Soft delete is enabled by default for all buckets that support it, with a default retention
     duration of 7 days."*
   - *"Soft-deleted objects continue to accrue storage charges until their retention period expires
     and they're permanently deleted."*
   - A bucket deleted under an active soft-delete policy is itself soft-deleted and restorable.
   - *"To disable soft delete, you set the retention duration to 0."*
3. So `force_destroy` deletes the objects Loki and Thanos wrote, they become soft-deleted, and they
   are billed for 7 days after a destroy that reports `destroy_retention: none`. Terraform's destroy
   succeeds with empty state: this is DEC-045 exception class 2b, deferred deletion that is billed.

## Why nothing catches it today

Terraform reports the bucket deleted, correctly by its own contract. Sol's destroy verification
describes the bucket as a live object, and a soft-deleted bucket's answer to that is not
established. No retention check covers GCS.

## Remedy shape (for INFRA-077)

Make GCS soft-delete retention a declared, policy-driven value rather than a provider default. Under
`destroy_retention: none` it must be `0` before the objects are deleted (either always for disposable
targets, or set by the Destroy-phase preparation before the destroy). Keep production's choice explicit
and separate. Verify it from the provider, and name what is retained in the retention report.

## Related

DEC-045 (exception classes), DEC-033, ADR 0004, FND-0006, FND-0046, INFRA-072.
