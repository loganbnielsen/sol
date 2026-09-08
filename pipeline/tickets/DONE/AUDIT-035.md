---
id: AUDIT-035
type: audit-finding
severity: medium
source: project/audits/2026-06-12e_homemade_code_audit.md
branch: AUDIT-035/cohttp-test-helpers
worktree: /home/lbendtly/Code/sun-AUDIT-035-cohttp-test-helpers
---

Replace duplicated raw HTTP test clients and servers with `cohttp-eio` test helpers

**Depends on:** AUDIT-030, AUDIT-031, AUDIT-032.

**Description:** Several tests include raw HTTP request/response code or copied URL/body parsing helpers, including `framework/sun-svc/test/test_service.ml`, `integrations/observability/obs-eio-loki/test/test_loki.ml`, `integrations/observability/obs-eio-prometheus/test/test_prometheus.ml`, and `integrations/kafka/kafka-eio-service/test/test_kafka_service.ml`. These tests open TCP sockets, write HTTP/1.1 strings, parse status lines, scan headers, and decode chunked or content-length bodies.

**Impact:** Tests that duplicate protocol parsing can pass while production code remains wrong, or fail because the test helper mishandles HTTP rather than because the product behavior regressed. This already happened with a copied `parse_base_url` test for schema registry HTTPS support.

**Remediation:**
1. Replace raw HTTP test clients and fake servers with `cohttp-eio` client/server helpers where practical.
2. Remove copied production parsers from tests; tests should call production helpers or exercise the public production path.
3. Keep only truly minimal raw TCP tests where the purpose is to validate raw HTTP server interoperability, and document those exceptions in comments.
4. Cover non-2xx responses, short bodies, chunked bodies if still relevant, and URL/path escaping through maintained HTTP tooling.
5. Run the affected test suites:
   - `eval $(opam env) && dune test framework/sun-svc/test`
   - `eval $(opam env) && dune test integrations/observability/obs-eio-loki/test`
   - `eval $(opam env) && dune test integrations/observability/obs-eio-prometheus/test`
   - `eval $(opam env) && dune test integrations/kafka/kafka-eio-service/test`

## Review — automated checks passed
All three test suites pass; raw TCP/HTTP framing replaced with Cohttp_eio.Client/Server throughout; no ticket files touched; no wrapped-true violations.
