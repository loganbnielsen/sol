---
id: INFRA-077
type: bug
severity: medium
title: GCS soft delete keeps a none-retention GCP target's observability data billed for 7 days after destroy
source: internal/pipeline/audits/findings/FND-0057-gcs-soft-delete-retains-billed-data-after-a-none-destroy.md
premise: "rg -q 'soft_delete_policy' cli/platform/infra/gcp/main.tf"
---

**Depends on:** None.

**Related:** FND-0057, DEC-045, DEC-033, REFAC-097.

## Problem

The GCP root's durable-observability buckets declare no `soft_delete_policy`, so Cloud Storage's
default applies: 7 days' retention of soft-deleted objects, billed at storage rates, with the bucket
itself soft-deleted and restorable. A `destroy_retention: none` destroy therefore reports absence
while the log and metric objects stay billed for a week (FND-0057, with the quoted documentation).

## Remediation

- Declare `soft_delete_policy { retention_duration_seconds = … }` on both buckets, routed through a
  variable so it is a decision, not a provider default. Follow the `deletion_protection` routing
  pattern that `check_destroy_completeness.sh` already enforces.
- Under `destroy_retention: none`, the value must be `0` before any object is deleted: either set it
  from the target's retention at creation, or have the Destroy-phase preparation lower it before the
  destroy (objects soft-deleted *before* a policy change keep their old retention, so the order
  matters; confirm this against the docs). Production keeps an explicit, documented value.
- Extend `check_destroy_completeness.sh`: every `google_storage_bucket` in a target root declares a
  `soft_delete_policy` (mutation-tested like the other rules).
- While here, settle DEC-045's open unknown for GCP retention: what Cloud SQL keeps (and bills) after
  instance deletion, given the root's `backup_configuration`. Record the answer from primary
  documentation in FND-0057, or file it separately if it needs a decision.

## Acceptance criteria

- Both buckets declare the policy via a variable; `none` yields `0`; production's value is explicit.
- The guard rejects a target-root GCS bucket without `soft_delete_policy` and accepts one with it.
- The retention report names what a GCP destroy retains (or states that it retains nothing), and the
  offline lifecycle harness covers `none` on GCP.
- Evidence class stays `STATIC`/`MECHANISM` until a live GCP run with durable observability
  (HARDEN-006) observes it; say so.
- Demo/example: not applicable (cloud lifecycle internals). Language parity (DEC-022): no
  application-facing impact.

## Completion notes (2026-09-25)

See FND-0057's 2026-09-25 transition for the mechanism and evidence. In short: the soft-delete
policy is declared on both buckets and routed from `destroy_retention` (`none` → 0; otherwise an
explicit 7 days); the guard enforces it, mutation-tested and positive-controlled against `main`; the
GCP retention report names it; and the Cloud SQL question is settled from Google's documentation plus
the locked provider's source (nothing is retained). `dune test cli/sol/test/` exit 0;
`terraform validate` of the GCP root passes; `check_ocamlformat.sh --all` clean.

- The choice was retention at creation, not a Destroy-phase lowering. Changing it at destroy time
  would add a constructive update to the destroy path (against the plan-asserted allowlists), and
  objects soft-deleted before a policy change keep their earlier retention, so the order would be
  fragile.
- Demo/example: not applicable (cloud lifecycle internals). Language parity (DEC-022): no impact.
- REFAC-092: no new provider constructor (the change sits inside the existing GCP arm).
