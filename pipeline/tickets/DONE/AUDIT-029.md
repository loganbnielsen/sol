---
id: AUDIT-029
type: audit-finding
severity: high
source: project/audits/2026-06-12d_audit.md
branch: AUDIT-029/schema-registry-tls
worktree: ../sun-AUDIT-029-schema-registry-tls
---

Implement TLS support in schema registry HTTP client

**Depends on:** None.

**Description:** `parse_base_url` in `integrations/kafka/kafka-eio-service/lib/kafka_service.ml` (lines 38–42) explicitly rejects `https://` URLs with `failwith "HTTPS schema registry not yet supported"`. AUDIT-013 changed this from a confusing DNS error to a clear failure message, but TLS was never implemented. All managed Kafka cloud offerings (Confluent Cloud, MSK, Redpanda Cloud) require HTTPS for their schema registry endpoint.

**Impact:** Sun cannot be used with any managed Kafka offering in production. Every cloud deployment that uses schema validation fails at worker startup with an explicit `failwith`.

**Remediation:**
1. Change `parse_base_url` to return `(string * int * bool)` where the third element is `use_tls`. Parse `https://` prefix and set `use_tls = true`, `port = 443` as default. Keep `http://` → `use_tls = false`, port 80.
2. Thread `use_tls` through `http_do_once` → open a TLS-enabled Eio socket when `use_tls = true`. Use `cohttp-eio` TLS support or `tls-eio` directly.
3. Update callers (`http_post`, `http_get`) and the `parse_base_url` API.
4. Add a test in `kafka-eio-service/test/` that verifies an `https://` URL parses correctly with `use_tls = true` and port 443.

## Review — returned for revision
- `integrations/kafka/kafka-eio-service/lib/kafka_service.ml:87` — When no CA bundle is found, the HTTPS schema registry client installs an authenticator that accepts any certificate, leaving TLS connections unverified instead of failing closed or using configured trust roots.
- `integrations/kafka/kafka-eio-service/test/test_kafka_service.ml:71` — The HTTPS parse test uses a copied local parse_base_url implementation rather than the production kafka_service.ml function, so it does not cover the required production behavior for use_tls=true and default port 443.

## Review — automated checks passed
AUDIT-029 fixes build cleanly and implement verified HTTPS schema registry support with production parse coverage and fail-closed CA handling.
