---
id: CODEX_STYLE_AUDIT-040
type: refactor
severity: medium
source: style audit
branch: codex/style-audit-040
worktree: /home/lbendtly/Code/sun-CODEX-040
---

Replace event `topic_name : string` contracts with typed topic descriptors.

**Depends on:** none.

**Problem:** `Kafka_service_intf.MESSAGE` exposes `val topic_name : string`, and
event modules under `examples/` repeat raw string topics. A typo or invalid topic
name compiles and fails at runtime.

**Goal:** Represent Kafka topics with a validated topic-name type.

**Acceptance criteria:**

- Add a topic-name constructor with Kafka-compatible validation.
- Update `MESSAGE`, `topic`, and sample event modules to use it.
- Keep string conversion at the Kafka raw/admin boundary.

## Review — automated checks passed

Focused Kafka service, worker, deployment-plan, example, and CLI builds pass.
Kafka topic names are now validated descriptors in the message contract, and
string conversion remains at raw Kafka/admin/schema/consumer boundaries.
