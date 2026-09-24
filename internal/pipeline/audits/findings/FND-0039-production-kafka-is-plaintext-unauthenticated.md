# FND-0039 — The production profile ships Kafka in plaintext without authentication; "plaintext only in dev" is not realised by any Sol path

- **Classification:** `DESIGN_GAP`
- **State:** `OPEN` — partly addressed by `SEC-007` (2026-09-24): the posture is
  now declared in every rendered manifest, required by `config_of_env`, and the
  documents state it honestly. Kafka is still plaintext and unauthenticated;
  closing this finding is FEAT-093.
- **First identified:** 2026-09-23, correctness audit
- **Last verified:** 2026-09-23 (`origin/main @ f3e9480b`; kafka-eio 0.3.0)
- **Derived ticket:** `SEC-007` (declare the posture), `FEAT-093` (BACKLOG — TLS/SASL, decision required)
- **Evidence class:** `STATIC`

## The claim

- `docs/architecture/PRODUCT_ARCHITECTURE.md:39`: *"… defaulting to plaintext only in
  dev and reading from environment variables in all other environments. You can't
  accidentally ship a production service with no security configuration because the
  type forces the field."*
- AGENTS.md, *Security on Day 1*: *"Dev defaults to `Plaintext`; the type forces all
  other environments to state their security posture explicitly."*
- `docs/planning/WORK_SUMMARY.md:2031`: *"production deployments set
  `KAFKA_SECURITY_PROTOCOL=ssl` and the code picks it up automatically."*

## What the code does

- `Kafka.Security.of_env` (kafka-eio `lib/kafka_security.ml:79-95`): an **absent**
  `KAFKA_SECURITY_PROTOCOL` is `Ok Plaintext`, in every environment. The type forces a
  value to exist. `of_env` supplies that value, so no environment ever has to state it.
- `default_cluster_env` (`cli/sol/lib/sol_cli_manifest_yaml.ml:41-51`) renders
  `KAFKA_BROKERS=…:9093`, `SCHEMA_REGISTRY_URL`, `REDPANDA_ADMIN_URL`, and **no**
  `KAFKA_SECURITY_PROTOCOL`.
- `cli/platform/components/redpanda/values-common.json:2`: `"tls": { "enabled": false }`.
  `values-durable.json` (the production shape) does not enable TLS or SASL. No Sol path
  (profile, target, manifest) sets either.

So every `sol deploy` workload, including production-profile targets, talks to Kafka
unencrypted and unauthenticated, while the documents say this cannot happen by
accident. The schema registry and admin API are plain HTTP as well.

## What is not established

Whether in-cluster plaintext protected by NetworkPolicy is an acceptable production
posture. That is the decision. This finding records that the current posture is
undeclared and contradicts the stated one, and that the "type forces it" argument does
not hold because `of_env` defaults.

## Decision needed

Either (1) state in the profile contract that in-cluster Kafka is plaintext and
unauthenticated by design, and correct the three claims; or (2) make the production
profile provision TLS (and SASL) on Redpanda, render `KAFKA_SECURITY_PROTOCOL` and the CA
into workloads, and make `of_env` refuse an absent protocol outside local. Option (2)
is what the architecture document promises.

## Related

CODEX_STYLE_AUDIT-026 (unknown protocol values now error; absence still defaults).
