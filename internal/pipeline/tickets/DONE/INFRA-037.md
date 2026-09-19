---
id: INFRA-037
type: bug
severity: high
title: Normal lifecycle activity must not make a target undeletable through the lifecycle
source: HARDEN-002 Run 5 Attempt 5 — sol cloud destroy failed on a healthy, Ready target
---

**Related:** ADR 0004 (the invariant and the retention distinction), ADR 0002 (Sol
owns the complete target lifecycle), ADR 0003 (phases and policy), HARDEN-002
(Attempt 5 record), INFRA-023 (unique final-snapshot identity).

## The finding

Attempt 5 built a conformant platform, reached `Ready`, re-entered through
`PlatformUpdating`, returned to `Ready` — and then could not destroy the target it
had just built:

```text
[terraform-destroy] FAILED (693.5s)
  Error: ECR Repository (pluto/checkout-svc) not empty, consider using force_delete
```

The repositories were not empty because **the documented publish step had filled
them**. Following the documented lifecycle correctly made the documented teardown
impossible. Nothing was wrong with the target.

Auditing the same question found the AWS failure was the *mildest* case, and that
the class exists on both providers:

| resource | before | consequence |
|---|---|---|
| `aws_ecr_repository.services` | no `force_delete` | teardown fails once anything is published |
| `aws_s3_bucket.{loki,thanos}` | `prevent_destroy = true` | terraform **refuses before attempting**; a durable-observability target can never be destroyed |
| `google_storage_bucket.{loki,thanos}` | `force_destroy = false` + `prevent_destroy = true` | same, on GCP |

All three are created by the target root and populated by *ordinary activity*:
deploying pushes images; running the platform for minutes fills log and metric
storage. So the lifecycle's own success defeated the lifecycle's last step.

## Decision (ADR 0004)

**Normal lifecycle activity must never make a target undeletable through the
normal lifecycle.** Resources a target root owns and ordinary activity populates
must be removable by that root's destroy, with their contents. `prevent_destroy`
must not appear in a target root — anything that must outlive a target belongs in
a different root (bootstrap), which is how the state bucket is already protected.
The rule is stated as a lifecycle property, not as Terraform arguments, because
`force_delete`/`force_destroy` are only how AWS and GCP spell it today.

Retention is explicitly *separate*: production destroy preserves recoverability
(final RDS snapshot, INFRA-023), while a disposable qualification target should
end with zero residual billable artifacts. Attempt 5 was cost-clean only because
the operator deleted the snapshot by hand — recorded as a deviation, and left open
in ADR 0004 as a follow-up because it changes what `sol cloud destroy` promises by
default.

## Acceptance criteria

- `aws_ecr_repository.services` sets `force_delete = true`, with the reason
  recorded where a reader will find it.
- The loki/thanos buckets on **both** providers are destroyable with their
  contents; no `prevent_destroy` remains in a target root.
- `terraform validate` succeeds for both target roots.
- A structural guard enforces the mechanical half — no `prevent_destroy` in a
  target root, and the force attribute on anything ordinary activity populates —
  covering both providers, written against the rule rather than a resource list.
- The guard is mutation-tested: it must reject ECR-without-force-delete,
  `prevent_destroy`, and GCP `force_destroy = false`, accept the repaired shape,
  and refuse a nonexistent root rather than passing silently.
- The guard rejects the pre-fix tree (it independently re-derives all five defects).
- CI runs both the mutation test and the guard.

## Not decided here

Making snapshot retention a target-level choice. It changes the default promise of
`sol cloud destroy`, so it needs its own decision rather than being smuggled in
with a bug fix.

**Demo/example coverage:** Not applicable — no CLI surface change.

**TypeScript parity:** No language-parity impact.
