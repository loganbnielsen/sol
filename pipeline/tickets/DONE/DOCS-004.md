---
id: DOCS-004
type: docs-finding
severity: critical
source: project/audits/2026-06-22_docs_audit.md
branch: DOCS-004/stale-kafka-service-config
worktree: ../sun-DOCS-004-stale-kafka-service-config
---

`kafka-eio-service.md` config type is stale: missing `admin_url` and `security` fields; topic provisioning incorrectly described as manual

**Description:** The spec at `integrations/kafka/kafka-eio-service/kafka-eio-service.md` documents the `config` record as `{ brokers; schema_registry_url; linger_ms; partitions }`. The actual type in `kafka_service.mli` also requires `admin_url : string` and `security : Kafka_security.t`. Any code constructed from the spec example is a type error.

The spec also states (in a "Note" block) that topic auto-provisioning is "planned for v2" and that "topics must be created externally." The current `.mli` docs for `register` say it "provisions M's topic via the Redpanda admin HTTP API" — provisioning is already implemented and uses the `admin_url` field.

**Impact:** Users reading the spec to build a config record get a compile error. Users believing topic provisioning is manual create unnecessary boilerplate that conflicts with the actual runtime behavior.

**Remediation:**
1. Update the spec's `config` record to include `admin_url : string` and `security : Kafka_security.t`.
2. Add a callout recommending `Kafka_service.config_of_env ()` as the standard way to construct config from environment variables.
3. Remove the "planned for v2 / external" note on topic provisioning and replace with accurate description of `register`'s behavior.

## Review — automated checks passed
All remediation items correctly applied: config record includes admin_url and security, stale v2/external note removed, config_of_env documented, create signature drops clock, register gains ~clock, publish shows ?trace_ctx, consume shows trace_ctx in handler with optional params, consume_partitioned documented, retry_strategy documented, Schema module documented, Confluent_wire documented, example uses config_of_env and updated signatures, no project/tickets/ changes in diff.
