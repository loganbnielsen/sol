---
id: FEAT-093
type: feature
severity: high
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

Provision TLS (and SASL) for Redpanda in production profiles and wire it into workloads

**Depends on:** None.

**Finding:** FND-0039 (`internal/pipeline/audits/findings/`).

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding).

## Problem

Production-profile Kafka, schema registry and admin API are plaintext and unauthenticated (FND-0039).

## Decision Required

Is in-cluster plaintext protected by NetworkPolicy an acceptable production posture (then close this as ACCEPTED in FND-0039), or must production encrypt and authenticate Kafka? SEC-007 makes the current posture explicit either way.

## Remediation

Enable Redpanda TLS (cert-manager-issued) and SASL in `values-durable.json` for production profiles; render `KAFKA_SECURITY_PROTOCOL=sasl_ssl`, CA path and SASL credentials (Secret) into workloads; HTTPS for registry/admin URLs.

## Acceptance criteria

- A production-profile target's workloads connect over SASL_SSL (HARDEN behavioural evidence).
- Local remains plaintext and is declared as such.

## Disposition (2026-10-03) — decision required

Smallest decision: is in-cluster plaintext Kafka behind NetworkPolicy an accepted production posture (close FND-0039 ACCEPTED), or must production run SASL_SSL? Consequence: requiring it changes `values-durable`, manifest rendering, the compatibility matrix and every live run; accepting is a recorded posture with no code change.

Surfaced to the operator as a category-5 decision; not deferred. Moves to
`READY_FOR_ENGINEERING/` once the decision is recorded. See
`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`.
