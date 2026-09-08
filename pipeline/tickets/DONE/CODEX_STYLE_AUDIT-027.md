---
id: CODEX_STYLE_AUDIT-027
type: refactor
severity: high
source: style audit
branch: CODEX_STYLE_AUDIT-027/typed-kafka-sasl-security
worktree: /home/lbendtly/Code/sun
---

Represent Kafka SASL requirements in the type instead of optional fields.

**Depends on:** CODEX_STYLE_AUDIT-026.

**Problem:** `Kafka_security.t` stores `sasl_mechanism`, `sasl_username`, and
`sasl_password` as independent options while `protocol` decides whether they are
required. `kafka_security.ml:50-59` performs runtime checks to reject invalid
combinations.

**Goal:** Encode valid security configurations in the type.

**Acceptance criteria:**

- Replace the flat record with variants for plaintext, TLS, SASL plaintext, and
  SASL over TLS.
- Ensure SASL constructors require mechanism, username, and password.
- Keep optional CA location on TLS-capable variants.
- Update tests and config application.

## Review — automated checks passed
CODEX_STYLE_AUDIT-027 passes review. Kafka_security.t is now a closed variant: Plaintext, Ssl with optional ssl_ca_location, Sasl_plaintext carrying required sasl credentials, and Sasl_ssl carrying optional ssl_ca_location plus required sasl credentials. Missing SASL env fields now fail during of_env parsing; apply no longer contains runtime checks for impossible missing credential combinations. Focused Kafka security tests and full branch pre-commit passed. Diff is scoped to kafka_security code/tests.
