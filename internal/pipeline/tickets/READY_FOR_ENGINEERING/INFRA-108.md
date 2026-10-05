---
id: INFRA-108
type: infra
severity: high
source: alpha.7 AWS attempt 2 and GCP attempt 5, 2026-10-04
title: Make the provider harnesses supply the documented pre-platform prerequisites
---

**Depends on:** None.

## Premise verified

`docs/deployment/production-bootstrap.md` §1 requires the broker's SASL users Secret before the
platform apply, and states the consequence: "The chart's `auth.sasl.secretRef` is `redpanda-users`;
when that Secret is absent the Redpanda release cannot start." `examples/pluto/README.md` carries the
same step for the runnable procedure. Neither `internal/qualification/aws/live-row.sh` nor
`internal/qualification/gcp/live-qual.sh` creates any Secret or runs any `kubectl create`/`apply`
(verified: neither file contains such an invocation), and the qualification targets declare no input
for it. Both harnesses therefore reach the platform apply with a documented prerequisite missing, and
every attempt fails there after roughly 700 seconds on either provider. BUG-206 owns the product
mechanism and records that no Secret was created by hand in either attempt either.

## Remediation

Make each harness perform the documented pre-platform steps, or refuse to start when an
operator-supplied input it cannot create is absent, naming that input. The campaign already supplies
`POSTGRES_URL` and `SOL_API_KEY` itself and records the fact without values; a broker credential
belongs in the same place: generated or operator-provided for the run, never committed, and recorded
as supplied rather than as a value. Keep FEAT-093's operator-owned SASL contract — the harness stands
in for the operator; it does not make the product create credentials.

## Acceptance criteria

- A harness run cannot reach the platform apply without the documented prerequisites satisfied; a
  missing one fails before any billable resource is created and names the input.
- The run record states which operator-supplied inputs were provided for the attempt, without values.
- The offline harness checks cover the missing-input path in both harnesses.
- Both harnesses and the runnable bootstrap procedure agree on the same ordered steps.
- Example impact: none; qualification machinery only. Language-parity impact: none; both languages
  share the broker and its credentials.
