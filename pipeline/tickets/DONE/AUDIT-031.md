---
id: AUDIT-031
type: audit-finding
severity: medium
source: project/audits/2026-06-12e_homemade_code_audit.md
---

Replace Loki hand-written HTTP and JSON construction with maintained libraries

**Depends on:** None.

**Description:** `integrations/observability/obs-eio-loki/lib/obs_loki.ml` hand-rolls both the Loki push HTTP client and Loki JSON payload construction. It manually parses `http://` URLs, opens TCP connections, writes HTTP/1.1 request strings, parses status lines and response snippets, and builds JSON with `Printf.sprintf "%S"` and string concatenation.

**Impact:** Observability code should be boring and reliable under failure. The current implementation has avoidable risk around URL parsing, HTTP response handling, JSON escaping, future HTTPS support, and Loki error reporting. The project already depends on `cohttp-eio`, `uri`, and `yojson`, which are better suited for this surface.

**Remediation:**
1. Replace the custom Loki HTTP client with `cohttp-eio` and `Uri`.
2. Build Loki push payloads with `Yojson.Safe` instead of string concatenation.
3. Preserve the public `Obs_loki.create ~net ~clock ~url ?label_names ()` API.
4. Preserve failure semantics: Loki push failures must be logged to stderr and must not raise through the observability backend.
5. Add or update tests for labels, trace fields, payload JSON shape, non-2xx error reporting, and short error bodies.
6. Remove raw `Eio.Net.with_tcp_connect`, `Eio.Flow.copy_string` HTTP request construction, status-line parsing, and manual JSON object construction from `obs_loki.ml`.
7. Run `eval $(opam env) && dune test integrations/observability/obs-eio-loki/test`.

## Review — automated checks passed
cohttp-eio + Yojson migration complete; build clean, all tests pass, no legacy TCP/jstr/jobj patterns remain
