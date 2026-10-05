---
id: INFRA-107
type: infra
severity: medium
source: alpha.7 campaign contract question Q1, 2026-10-04
title: Make disposable qualification targets fresh by default
---

**Depends on:** None.

## Premise verified

`internal/qualification/aws/live-row.sh` still defaults to `qualreg/aws/us-east-1`; GCP defaults to `qual/gcp/us-central1`. Neither default creates a fresh environment/state key per attempt. The alpha campaign's clean-start condition and the observed absent-state bug require first-run qualification without inherited state.

## Remediation

Require an explicit new disposable target identity for each run, or derive one safely from the run identity after checking it is absent. Keep a stable logical row label separate from the environment/state key. Preserve the existing durable-root bucket and zone.

## Acceptance criteria

- A repeated invocation cannot silently reuse an old disposable target as a fresh qualification run.
- The target identity and state key appear in the run record and provider inventory.
- Offline harness checks cover an occupied key and a fresh key. Example impact: none; qualification machinery only. Language-parity impact: none.
