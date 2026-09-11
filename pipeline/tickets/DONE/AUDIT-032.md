---
id: AUDIT-032
type: audit-finding
severity: medium
source: project/audits/2026-06-12e_homemade_code_audit.md
---

Replace Pushgateway hand-written HTTP client with `cohttp-eio`

**Depends on:** None.

**Description:** `integrations/observability/obs-eio-prometheus/lib/obs_prometheus.ml` hand-rolls the Pushgateway client. It manually parses URLs, percent-encodes the job path, writes a raw HTTP/1.1 PUT request, opens a TCP socket, and parses the status line.

**Impact:** Pushgateway delivery is part of the scheduled-function observability path. The current code has avoidable edge cases around URL parsing, path escaping, HTTPS support, Host header formatting, and response handling. `cohttp-eio` and `uri` should own the HTTP details.

**Remediation:**
1. Replace `parse_url`, raw request construction, and direct TCP status-line parsing in `Obs_prometheus.push` with `cohttp-eio` and `Uri`.
2. Use `Uri` path construction or a maintained escaping helper for `/metrics/job/<job>`.
3. Preserve the public `push ~net ~clock ~url ~job renderer` API and return semantics.
4. Preserve timeout behavior and non-2xx error reporting.
5. Add or update tests for job names requiring escaping, explicit ports, non-2xx responses, and empty renderer output.
6. Run `eval $(opam env) && dune test integrations/observability/obs-eio-prometheus/test framework/sun-fn/test`.

## Review — automated checks passed
Hand-written HTTP client replaced with cohttp-eio; build clean, all tests pass, public API unchanged, no project/tickets changes
