---
id: PROD-001
type: verification
severity: high
title: Qualify and operate the first maturity-A production pilot
source: production platform contract review 2026-09-16
---

**Depends on:** HARDEN-002.

## Goal

Put one real, non-critical customer-facing workload under the validated
`production-single-region` contract with a named owning team. This is the
maturity-A launch gate, not another implementation epic.

## Entry criteria

- DEC-026 and DEC-027 are decided and reflected in the shipped profile.
- HARDEN-002 passes on a clean target with a reviewable evidence bundle.
- The owning team accepts the guarantees, exclusions, SLOs, alerts, runbooks and
  recovery duties.
- The workload fits the profile; exceptions are not silently waived.

## Pilot runbook

1. Provision the supported target using the named production identities.
2. Deploy the exact qualified artifact digests and verify a real customer
   transaction.
3. Send real but explicitly non-critical traffic.
4. Exercise failed deployment, rollback, node loss/drain, dependency loss,
   restore, credential rotation and alert delivery with the owning team.
5. Record incidents, operator confusion and contract mismatches as findings;
   only failures of a claimed guarantee block maturity A.
6. Hold a launch review against the completion criteria below.

## Maturity-A completion criteria

- The target explicitly selects a versioned production profile; an environment
  name alone grants no production claim.
- The selected reconciliation authority, artifact digests, supported versions,
  remote state and named identities are visible and verified.
- Every workload meets its declared availability semantic.
- Postgres, Kafka and any admitted volume meet only the written durability and
  recovery claims, with successful restore evidence.
- Required alerts reach a named human and every alert has an owner/runbook.
- Runtime credential rotation has passed.
- The complete HARDEN-002 scenario set is green for capabilities the pilot uses.
- The real non-critical workload is serving customer traffic and its team can
  deploy, diagnose, roll back and recover it without inventing missing procedure
  during the exercise.
- Fixed capacity, one region, no regional failover, one-team operation and any
  unsupported provider/language are explicit limitations.

## Explicitly not required

Autoscaling, multi-team RBAC/governance, hosted control plane, fleet management,
metering, regional failover, organization-scale audit retention, admission
policy, artifact signing or a generalized policy language.

**Demo/example coverage:** The pilot workload and sanitized conformance record
become the runnable/reference example for the profile.

**TypeScript parity:** The pilot uses only languages included by DEC-026; broader
qualification remains a separately visible follow-up, never an implied claim.
