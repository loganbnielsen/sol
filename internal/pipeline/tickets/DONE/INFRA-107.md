---
id: INFRA-107
type: infra
severity: medium
source: alpha.7 campaign Q1 and GCP attempt 5 evidence contamination, 2026-10-04
title: Bind disposable targets and evidence to one qualification attempt
---

**Depends on:** None.

## Premise verified

Re-verified 2026-10-04 on the INFRA-106 worktree. `internal/qualification/aws/live-row.sh`
defaulted `TARGET` to `qualreg/aws/us-east-1` and derived `STATE_KEY` from it;
`internal/qualification/gcp/live-qual.sh` defaulted to `qual/gcp/us-central1`. Neither
looked at whether that state object already existed, so attempt 5 reused the prior
target's Terraform state, evidence directory and cluster name: its waiter accepted the
old kubeconfig `observer.py` matched by name alone, and its failure directory mixed
attempt-4 captures. `observer.py` compared a name substring only, never the endpoint.

## Remediation

A shared `internal/qualification/attempt.sh` makes one attempt identity first-class.
Each mutating harness requires `ATTEMPT`, derives a per-attempt disposable target
(`$ROW-$ATTEMPT/<provider>/<region>`, keeping the stable `ROW` label separate) and a
per-attempt evidence directory, writes `attempt.txt` (attempt, row, target, state key,
cluster, provider) into the bundle, and refuses to open a directory that records another
attempt or none. The `cloud` phase checks the disposable state key for absence before any
mutation and refuses an occupied key unless the same attempt is being continued
(`CONTINUE_ATTEMPT=1` or the directory's own identity); a refusal tears nothing down,
because it did not create the target. The observer now binds a kubeconfig entry to the
provider-reported endpoint (normalised to a bare host) and reports a same-name replaced
cluster as no credential; the GCP waiter, failure capture and FND-0010/Ready captures all
pass that endpoint, so a stale kubeconfig is never read as evidence. API-readiness samples
carry the attempt identity, the capture summary carries it, and both provider inventories
carry the attempt, target and state key.

## Acceptance criteria

- A repeated invocation cannot silently reuse an old disposable target as a fresh
  qualification run.
- The target identity and state key appear in the run record and provider inventory.
- Offline harness checks cover an occupied key, a fresh key, reused evidence directories
  and a recreated same-name cluster with a different endpoint.
- API observations cover the actual platform apply interval; each capture carries the
  attempt identity.
- Existing failure files cannot become evidence for a later attempt.
- Example impact: none; qualification machinery only. Language-parity impact: none.

## Checks

- `internal/qualification/gcp/test-live-qual.sh` — 290 passed, including new scenarios:
  an occupied state key refused with nothing applied or torn down; an evidence directory
  for another attempt refused; a credential for a replaced same-name cluster reported as
  no credential, with the endpoint-binding reason; the attempt identity asserted on every
  API-readiness sample, in the manifest and in the provider inventory.
- `internal/qualification/aws/test-live-row.sh` — 87 passed, including the same occupied-key,
  foreign-directory, replaced-endpoint and identity-in-inventory scenarios.
- `python3 internal/qualification/gcp/test_observer.py` — 38 passed; the new checks bind a
  matching endpoint and reject a replaced cluster's endpoint.
- `internal/ci/check_no_comments.sh` and the fast guard suite pass (apart from the
  ticket-move guard, which passes once this ticket's move is committed).

## Completion notes

The harness now refuses to start a fresh attempt against an occupied state key, binds its
evidence directory and every capture to the attempt, and never reads a kubeconfig whose
endpoint is not the current cluster's. The documented run procedures must now pass
`ATTEMPT`; the harness usage text states it. Example impact: none; qualification machinery
only, no demo or reference-application change. Language-parity impact: none; both
harnesses share the mechanism and the provider streams are language-neutral.
