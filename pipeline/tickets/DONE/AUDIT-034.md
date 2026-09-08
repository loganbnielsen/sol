---
id: AUDIT-034
type: audit-finding
severity: medium
source: project/audits/2026-06-12e_homemade_code_audit.md
---

Replace manual Confluent wire-format byte indexing with a dedicated `cstruct` codec

**Depends on:** None.

**Description:** `integrations/kafka/kafka-eio-service/lib/kafka_service.ml` encodes and decodes Confluent wire-format messages with direct `Bytes.create`, `Bytes.set`, `Bytes.get`, `Bytes.blit_string`, `Char.chr`, `Char.code`, and manual bit shifts. The tests duplicate the same byte-level codec.

**Impact:** The wire format is small, but manual byte indexing is brittle and easy to duplicate incorrectly. It also makes it harder to audit bounds checks and integer encoding. The project already depends on `cstruct`, which provides maintained big-endian binary helpers and a clearer abstraction for byte-level protocols.

**Remediation:**
1. Move Confluent wire-format encode/decode into a small dedicated module or internal section using `Cstruct` big-endian helpers.
2. Preserve the exact wire format: magic byte `0x00`, four-byte big-endian schema ID, followed by the JSON payload.
3. Make decode errors explicit for too-short messages, bad magic byte, and malformed schema ID/payload.
4. Update tests to exercise the production codec instead of duplicating encode/decode logic.
5. Keep the public `publish`, `consume`, and `consume_partitioned` behavior unchanged.
6. Run `eval $(opam env) && dune test integrations/kafka/kafka-eio-service/test`.
