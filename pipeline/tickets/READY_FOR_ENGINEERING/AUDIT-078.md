---
id: AUDIT-078
type: audit-finding
severity: high
title: Define and prove application-data durability and recovery
source: production-readiness reviews 2026-09-16; consolidates Kafka, database HA and restore findings with FEAT-083 as a prerequisite
---

**Depends on:** DEC-026, FEAT-083.

## Production guarantee

Application data used by a workload admitted to `production-single-region` is
protected and recoverable to the exact durability and availability level stated
by the profile. Postgres, Kafka and workload volumes are distinct capabilities;
telemetry and Terraform/control state have separate contracts.

## Existing evidence consolidated here

- Every Kafka topic created by the OCaml framework currently hard-codes
  replication factor 1 (original AUDIT-078).
- The AWS RDS module has no Multi-AZ option while GCP exposes regional HA.
- Backups/PITR are configured, but no restore has been demonstrated.
- Replica/volume semantics are unresolved in FEAT-083.

## Decision boundary

DEC-026 must define measurable Postgres and Kafka recovery/data-loss expectations
and whether the first profile claims AZ tolerance. FEAT-083 defines portable
workload-volume semantics. This ticket must not turn replication factor,
Multi-AZ or a CSI mode into the public API.

## Implementation scope

- Derive Kafka topic durability from target capability/policy and fail closed
  when the substrate cannot provide it.
- Apply the same Kafka durability convention to every supported language.
- Add database HA configuration only if the profile claims the corresponding
  failure tolerance; otherwise document zonal outage as an exclusion.
- Define backup, restore and integrity-verification procedures for Postgres and
  every admitted application-volume class.
- Keep telemetry retention/HA and regional failover outside the application-data
  guarantee.

## Conformance and acceptance criteria

- Loss of one broker does not lose acknowledged events when the profile claims
  broker-loss tolerance; processing resumes within the stated bound.
- A target that cannot meet the required Kafka durability fails before topic
  creation instead of silently downgrading.
- Database dependency loss produces the documented workload behavior.
- Restore into a clean qualification target meets the profile's RPO/RTO and
  passes application-level integrity checks, not merely provider job completion.
- Any admitted persistent-volume semantic has a tested restore/replacement path;
  otherwise the profile rejects it.
- HARDEN-002 records broker-loss, dependency-loss and restore evidence.

## Non-goals

- Cross-region replication or failover.
- One universal durability class for application data, control state and
  telemetry.
- Exposing provider replication or Kubernetes storage knobs to applications.

**Demo/example coverage:** The production-profile example must exercise the
supported Postgres/Kafka path; add a volume example only if DEC-026 admits
persistent workload volumes.

**TypeScript parity:** Kafka durability is a platform capability and must hold for
both language implementations included by DEC-026.
