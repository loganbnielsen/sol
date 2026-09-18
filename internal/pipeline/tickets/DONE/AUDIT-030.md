---
id: AUDIT-030
type: audit-finding
severity: high
source: project/audits/2026-06-12e_homemade_code_audit.md
---

Replace schema registry/admin hand-written HTTP client with `cohttp-eio`

**Depends on:** None.

**Description:** `integrations/kafka/kafka-eio-service/lib/kafka_service.ml` contains a custom HTTP/1.1 client for schema registry and Redpanda admin calls. It manually parses URLs, builds request strings, parses status lines and headers, handles `Content-Length`, decodes chunked responses, and wires TLS setup directly. This is exactly the kind of protocol code that should be owned by a maintained Eio-compatible HTTP package. `cohttp-eio` and `uri` are already project dependencies.

**Impact:** Subtle HTTP/TLS behavior can be wrong or incomplete: IPv6 literals, paths in base URLs, default ports, Host header formatting, chunk extensions, redirects, connection errors, TLS trust configuration, and response body handling. Managed schema registries are production-critical, so this code should not be a bespoke parser.

**Remediation:**
1. Replace `parse_base_url`, `tls_authenticator`, and the custom `http_do_once` request/response parser with a `cohttp-eio` + `Uri` implementation.
2. Preserve the existing public behavior of `http_post`, `http_put`, and `http_get`: return `(status, body)` on success and `Error string` on connection/timeout/protocol failure.
3. Preserve HTTPS support and fail-closed certificate verification.
4. Support both schema registry URLs and Redpanda admin URLs, including explicit paths and explicit ports.
5. Remove direct `Eio.Net.with_tcp_connect`, raw HTTP request strings, manual chunk decoding, and manual CA file reads from `kafka_service.ml`.
6. Update tests so HTTPS URL parsing/behavior is covered through the production HTTP path or through a small production helper backed by `Uri`, not by copied parsing code.
7. Run `eval $(opam env) && dune build` and the `kafka-eio-service` unit tests.

## Review — automated checks passed
Raw TCP/HTTP framing replaced with cohttp-eio; TLS preserved fail-closed; public API unchanged; build and unit tests pass; diff confined to kafka-eio-service lib and test files only
