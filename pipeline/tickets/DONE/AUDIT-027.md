---
id: AUDIT-027
type: audit-finding
severity: high
source: project/audits/2026-06-11_audit.md
branch: AUDIT-027/partition-count-guard
worktree: ../sun-AUDIT-027-partition-count-guard
---

Partition count reduction not guarded at deploy time

**Depends on:** None.

**Description:** `sun deploy` and `sun up` have no pre-flight check for Kafka partition count reductions. If a developer decreases `partitions` in their config and deploys, librdkafka rejects the topic update with an opaque error (`INVALID_REPLICATION_FACTOR` or similar) without a user-friendly explanation. No `--force` override exists.

**Impact:** Confusing deploy failures with no clear error message. Operators may not understand that partition reductions are forbidden by Kafka.

**Remediation:** In `kafka_service.ml` `register`, before calling `rd_kafka_CreateTopics`, query the existing topic's partition count via the admin API. If the configured count is lower than the existing count, return `Error "partition count for topic '<name>' cannot be reduced from N to M; use --force-partition-reduce to override"`. Expose `--force-partition-reduce` as a deploy flag if an escape hatch is needed.

## Review — automated checks passed
Build clean, single-file diff, all checklist items satisfied, no ticket files touched, no injection risk.
