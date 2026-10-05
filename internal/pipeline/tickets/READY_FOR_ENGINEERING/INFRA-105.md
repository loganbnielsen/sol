---
id: INFRA-105
type: infra
severity: low
source: alpha.7 GCP qualification attempts, 2026-10-04
title: Require the FND-0010 classification artifact only when classification runs
---

**Depends on:** None.

## Premise verified

The GCP harness evidence manifest requires `fnd0010-classification.txt`; early failures before its classifier runs leave the bundle marked incomplete. The failure-capture path does produce it when reached.

## Remediation

Make artifact requirements phase-aware or emit an explicit not-reached classification. Preserve a failing verdict for missing evidence in phases that did run.

## Acceptance criteria

- A pre-provisioning validation failure yields a complete, correctly failed evidence bundle.
- A reached classifier without its artifact remains an evidence failure.
- Example impact: none; qualification machinery only. Language-parity impact: none.
