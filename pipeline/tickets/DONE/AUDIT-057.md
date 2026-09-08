---
id: AUDIT-057
type: audit-finding
severity: medium
source: codebase review 2026-06-14
branch: AUDIT-057/kafka-security-result-errors
worktree: /home/lbendtly/Code/sun-AUDIT-057-kafka-security-result-errors
---

Return typed Kafka security configuration errors instead of raising `Failure`

**Depends on:** None.

**Description:** `integrations/kafka/kafka-eio-core/lib/kafka_security.ml` applies security settings with:

```ocaml
| Error s -> failwith ("kafka security conf " ^ k ^ ": " ^ s)
```

Producer and consumer configuration builders otherwise accumulate librdkafka config errors and return `Error`, but any invalid security field can bypass that path and raise.

**Impact:** Bad SASL/TLS configuration can crash process startup with an exception instead of returning a structured `Kafka_error.Application` or readable config error. This is especially likely in production deployments where credentials and security protocol are environment-driven.

**Remediation:**

1. Change `Kafka_security.apply` to return `(unit, string) result`.
2. Update producer and consumer `conf_of_config` functions to compose those errors with their existing config error handling.
3. Validate required combinations, such as SASL protocols requiring username/password/mechanism.
4. Add tests for invalid librdkafka keys/options and missing SASL fields.

**Acceptance criteria:**

- `Kafka_security.apply` no longer calls `failwith`.
- Producer and consumer creation return typed errors for invalid security configuration.
- Error messages identify the failing security setting.
- Existing Kafka producer/consumer/service tests continue to pass.

## Review — automated checks passed
Kafka_security.apply now returns (unit, string) result with typed SASL validation; producer and consumer handle the result correctly; all 7 new tests pass; no failwith remains at the security boundary
