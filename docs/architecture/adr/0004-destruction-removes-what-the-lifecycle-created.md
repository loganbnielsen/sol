# ADR 0004: destruction removes what the lifecycle created

- Status: Accepted
- Date: 2026-09-19
- Supersedes: nothing
- Related: ADR 0002 (Sol owns the complete cloud target lifecycle), ADR 0003
  (lifecycle phases, authority and policy), HARDEN-002 (Run 5 Attempt 5)

## Context

`sol cloud destroy` is the only supported way to take a target apart. A
qualification run on a real AWS target (HARDEN-002 Run 5, Attempt 5) got all the
way to `Ready`, re-entered through `PlatformUpdating`, and then **failed to
destroy the target it had just built**:

```text
[terraform-destroy] FAILED (693.5s)
  Error: ECR Repository (pluto/checkout-svc) not empty, consider using force_delete
```

The repositories were not empty because the documented publish step
(`sol deploy`'s image push) had filled them. The failure did not come from a
broken target: the target was healthy, the lifecycle was followed exactly as
documented, and the two ends of that lifecycle disagreed.

Auditing the same question across both providers showed the AWS failure was the
mildest instance of the class:

| resource | state before this ADR | consequence |
|---|---|---|
| `aws_ecr_repository.services` | no `force_delete` | destroy fails once anything is published |
| `aws_s3_bucket.loki` / `.thanos` | `prevent_destroy = true` | destroy **refuses before attempting**; a durable-observability target can never be removed |
| `google_storage_bucket.loki` / `.thanos` | `force_destroy = false` **and** `prevent_destroy = true` | same, on GCP |

Every one of these is a resource the *target root itself* creates and that
*ordinary platform activity* populates: images are pushed by deploying, and log
and metric storage is filled by running the platform for a few minutes. So the
lifecycle's own success made the lifecycle's last step impossible.

## Decision

**Normal lifecycle activity must never make a target undeletable through the
normal lifecycle.**

Concretely, for any resource a target root creates:

1. If ordinary lifecycle activity can populate it, that same root's destroy must
   be able to remove it *with its contents*. `force_delete` for ECR
   repositories, `force_destroy` for object storage.
2. `prevent_destroy` must not be used on resources owned by a target root. A
   resource that must survive a target's destruction does not belong to that
   target's root.
3. Shared, longer-lived state that legitimately must outlive one target — the
   Terraform state bucket and lock table, for instance — is protected by living
   in a **different root** (bootstrap), not by `prevent_destroy` inside the
   target. That is why this ADR removes those blocks rather than softening them.

This is deliberately stated as a property of the lifecycle rather than as a list
of Terraform arguments. `force_delete = true` and `force_destroy = true` are how
AWS and GCP currently express it; the rule is what governs new resources,
new providers, and any future artifact kind (caches, registries, backups).

## Retention is a separate, explicit decision

Destroy still has to decide what to *deliberately* keep. Two situations differ:

- **Production**: `sol cloud destroy` preserves recoverability. The Destroy policy
  keeps a final RDS snapshot (`rds_skip_final_snapshot = false`, a unique
  per-attempt identifier — INFRA-023). Cost-clean here means "nothing running",
  not "nothing retained".
- **Disposable qualification targets**: the point is to prove the lifecycle and
  then leave nothing billable behind. HARDEN-002 Attempt 5 finished cost-clean
  only because the operator deleted the final snapshot by hand afterwards, which
  is precisely the kind of manual step that should not be required.

The distinction must be explicit and driven by the target, not by an operator
remembering. Until that control exists, "the target destroyed cleanly" for a
disposable target means: **zero residual billable artifacts, including
snapshots**, and the operator's manual deletion is recorded as a deviation.

## Consequences

- `sol cloud destroy` completes on a target that has published images and filled
  its log/metric buckets, on both providers, with no manual intervention.
- Destroying a target now destroys data that would otherwise have been retained
  by accident: log chunks and metrics blocks in object storage. That is
  intentional — the bucket belongs to the target — but it means object storage
  must never be the only home of anything a target is expected to outlive.
- The invariant is cheaper to hold than to recover from. What Attempt 5 cost was
  not the failed command; it was that a healthy target became undeletable, which
  is the one failure mode that keeps billing.
- A structural guard (`internal/ci/check_destroy_completeness.sh`) enforces the
  mechanical half: no `prevent_destroy` in a target root, and every resource that
  ordinary activity populates carries the force attribute.

## Retention is now decided (DEC-033)

A target names what its destruction keeps:

- **absent** — the production default is unchanged. `sol cloud destroy` retains the
  final snapshot, and the destroy reports it by identifier along with the command
  that eventually removes it, so retention is explicit rather than inferred.
- **`destroy_retention: none`** — a disposable qualification target. Its
  postcondition is `Absent` with no residual billable artifacts, and the destroy
  says so.

The two are different postconditions, and neither is the other's default: a
qualification target opting out does not turn "this run retains nothing" into "Sol
destroys every recovery artifact".
