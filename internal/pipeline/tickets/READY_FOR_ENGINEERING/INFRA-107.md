---
id: INFRA-107
type: infra
severity: medium
source: alpha.7 campaign Q1 and GCP attempt 5 evidence contamination, 2026-10-04
title: Bind disposable targets and evidence to one qualification attempt
---

**Depends on:** None.

## Premise verified

`internal/qualification/aws/live-row.sh` still defaults to `qualreg/aws/us-east-1`; GCP defaults to `qual/gcp/us-central1`. Neither default creates a fresh environment/state key per attempt. GCP attempt 5 reused the prior evidence directory and cluster name; its waiter accepted the old kubeconfig immediately, the API probe used the old endpoint, and old failure captures remained in the bundle. The alpha campaign's clean-start condition and the observed absent-state bug require first-run qualification without inherited state.

## Remediation

Require an explicit new disposable target identity for each run, or derive one safely from the run identity after checking it is absent. Keep a stable logical row label separate from the environment/state key. Preserve the existing durable-root bucket and zone. Use one evidence directory per attempt or refuse reuse, and bind kubeconfig to the current cluster generation and endpoint. Matching the cluster name alone is insufficient. Keep API observation active during platform apply, and reject stale captures.

## Acceptance criteria

- A repeated invocation cannot silently reuse an old disposable target as a fresh qualification run.
- The target identity and state key appear in the run record and provider inventory.
- Offline harness checks cover an occupied key, a fresh key, reused evidence directories and a recreated same-name cluster with a different endpoint.
- API observations cover the actual platform apply interval; each capture carries the attempt identity.
- Existing failure files cannot become evidence for a later attempt. Example impact: none; qualification machinery only. Language-parity impact: none.
