---
id: INFRA-104
type: infra
severity: medium
source: alpha.7 GCP qualification attempt 1, 2026-10-04
title: Keep the GCP qualification target's resources consistent with the reference service
---

**Depends on:** None.

## Premise verified

`internal/qualification/gcp/live-qual.sh` writes a target with `orders_svc` using `app_db` and `events`, but omits those resource declarations on current main. Sol correctly rejects it before provisioning. A local unpushed patch exists in the campaign worktree.

## Remediation

Apply the minimal target correction and retain an offline `sol check` case for the generated target. The alpha scenario requires managed Postgres and Redpanda on cloud targets.

## Acceptance criteria

- The generated GCP target declares both resources and passes `sol check` before any provider call.
- The runnable reference scenario remains the source for the service's `uses` declaration. Language-parity impact: none; this is a language-neutral target.
