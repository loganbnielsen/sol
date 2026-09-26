---
id: HARDEN-008
type: verification
severity: high
title: GCP attempt 10 — confirm the FND-0010 fix: cert-manager's readiness check passes and the install continues (Ready if it does)
source: FND-0010's established cause (the platform apply cut cert-manager's own readiness check short) and its fix in the shared platform module
---

**Depends on:** None.

**Related:** `FND-0010`, `HARDEN-006` (Attempt 9, DONE), `INFRA-080`, `FND-0058`,
`docs/qualification/README.md`, `internal/qualification/gcp/live-qual.sh`.

## Goal

One fresh GCP attempt whose purpose is to see whether the platform now installs past
cert-manager:

> Start the platform, let cert-manager's own readiness check run to its conclusion, and see
> whether the installation continues — to `Ready` if the rest of the platform installs.

This is a **confirmation** run, not a discriminator run: FND-0010's cause is established
(Attempt 9's product log shows `failed post-install: ... timed out waiting for the condition`
exactly 300s after the chart's post-install hook Job was created, i.e. the Helm provider's
default `timeout` cutting off a check cert-manager designed to keep polling) and fixed.

## What must be true before it starts

- canonical `main` contains the FND-0010 fix (`platform/cloud/modules/platform/main.tf`) and
  `internal/ci/check_cert_manager_readiness.sh` is green;
- `PHASE_TIMEOUT` is at least the release bound (1800s): the runbook's 2700s is enough, the
  harness's own default of 1200s is not;
- the standard read-only preflight (disposable classes ABSENT, durable prerequisites PRESENT,
  quota 0, no UNKNOWN, delegation resolving, fresh target key, revision/binary match);
- explicit operator authorization (this ticket stays in `BACKLOG` until then).

## What it must observe

1. the `cert-manager-startupapicheck` Job reaches `Succeeded` (or the release completes
   without a failed post-install);
2. the platform apply continues past cert-manager — the CRDs are Established, the rest of the
   platform installs — and, if it gets that far, `Ready`;
3. if the check still fails, the widened discriminator captures the CA/TLS Secrets
   (metadata and key names only) and the controller/webhook/cainjector logs, so the *next*
   question — did the CA secret ever appear, and did cainjector inject? — is answered from
   evidence rather than by another run;
4. supported teardown, both Terraform roots empty, and the first teardown whose verdict
   INFRA-080's corrected semantics can call truthfully clean.

## What a failure means

If the check still fails after its full 10-minute poll windows, that is a **new finding**
(CA injection never converging in this environment), not a reopened FND-0010: the fix claims
only that Sol now waits as long as cert-manager's own contract is designed to wait. Capture,
freeze and stop; do not remediate inline.

## Value beyond FND-0010

A `Ready` platform is the precondition for `INV-DESTROY-1`'s and `INV-DESTROY-4`'s `Ready`
cases, every `INV-SUBSTRATE-*` row, and application-level qualification — none of which any
attempt has reached.

## Acceptance criteria

- the run record exists in `docs/qualification/`, with the startupapicheck outcome, the
  release's elapsed time, and (if reached) the `Ready` evidence;
- `FND-0010` moves to `QUALIFIED` **only if** the check passed and the install continued;
- any further failure is filed as its own finding with the widened discriminator attached;
- supported teardown verified, durable prerequisites intact, no billable residue.
