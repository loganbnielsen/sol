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

## Input from FEAT-089: Kafka use has no declaration

The production profile makes Kafka durability applicable only on positive,
language-neutral evidence: topics declared in `events/` `sol.toml`, or a
`kafka` resource in `sol.yml`. A worker's shape implies nothing, since DEC-021
lets a `-worker` host `sol-jobs` instead of a Kafka consumer. But a Kafka
consumer can exist with neither signal: its topic is named in code and created
at runtime.

Before Kafka durability can be established, this ticket must define how a
workload declares its Kafka dependency, so the profile cannot miss one. The
declaration must be language-neutral; inferring Kafka use from worker shape or
from language source files is not acceptable. The existing `derive_consumer_groups`
convention, which assigns a consumer group to every worker, makes the same
shape-based assumption and should be reconciled with that declaration.

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

## Outcome (2026-09-17)

The profile's application-data guarantees now become applicable through one
language-neutral declaration and fail closed when the substrate cannot meet
them.

- **Kafka use is declared, not inferred.** A service declares a Kafka
  dependency by listing a `kafka` resource in its `uses:`. The plan sets
  `SOL_KAFKA_DURABILITY=single-broker-loss` only for those services, and
  `derive_consumer_groups` now derives a consumer group only for workers that
  make that declaration — reconciling the old shape-based assumption. A target
  with a `kafka` resource or an `events/` topic but no service declaring its use
  fails preflight on the application side, naming the `uses:` fix.
- **Kafka durability is a semantic policy, not a knob.** `Kafka_service` grew
  `topic_durability` (`Broker_default` / `Single_broker_loss`). The qualified
  path creates topics with replication factor 3 and rejects an existing topic
  whose Redpanda metadata reports fewer replicas with `Insufficient_replication`,
  before schema registration. Redpanda itself refuses RF 3 on a substrate with
  too few brokers, so a target that cannot provide the guarantee fails rather
  than silently downgrading. The admin partition query moved to Redpanda's
  `/v1/partitions/kafka/<topic>` (the old `/v1/topics/<topic>` is 404), which is
  what exposes each partition's replica count.
- **Postgres HA follows the profile.** The AWS RDS module gained `rds_multi_az`;
  the production profile derives it `true`, and profile-derived Terraform
  variables are applied after operator `--var`/var-file values so a profile
  invariant is not an escape hatch.
- **Recovery is written down.** `docs/deployment/application-data-recovery.md`
  defines the Postgres PITR/failover and Redpanda broker-loss operator
  procedures plus the admitted volume semantic (single-AZ, replace from the
  application artifact, no backup claim). HARDEN-002 records the qualification
  evidence.

Premise check: on pickup, `kafka_service_intf.ensure_topic` still pinned
`replication_factor:1` and the AWS RDS module had no Multi-AZ variable, so the
finding was still actionable.

**Demo/example coverage:** `examples/pluto` already declares the `events` Kafka
resource and lists it in `charge_svc`/`notify_worker` `uses`, so the pilot
target exercises the supported Postgres/Kafka path. DEC-026 admits a workload
volume only at `single` with no backup claim, so no volume example is added.

**TypeScript parity:** Kafka durability is a platform capability, but
TypeScript is staged behind DEC-026 §2's triggers and `@sol-fab/worker` does not
create topics today, so no TypeScript change is in scope for maturity A.
