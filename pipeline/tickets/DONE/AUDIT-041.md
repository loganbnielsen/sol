---
id: AUDIT-041
type: audit-finding
severity: high
source: project/audits/2026-06-12j_audit.md
branch: AUDIT-041/observability-tls
worktree: /home/lbendtly/Code/sun-AUDIT-041-observability-tls
---

`obs_loki.ml` and `obs_prometheus.ml` pass `~https:None` — HTTPS Loki/Pushgateway endpoints silently drop all observability data

**Depends on:** None.

**Description:** Both observability backends construct their Cohttp_eio client with `~https:None`:
- `integrations/observability/obs-eio-loki/lib/obs_loki.ml` line 14
- `integrations/observability/obs-eio-prometheus/lib/obs_prometheus.ml` line 242

When `~https:None` is passed, Cohttp_eio refuses HTTPS URIs at connection time — no TLS handshake is attempted. Cloud-hosted Loki endpoints (Grafana Cloud `logs-prod-*.grafana.net`, self-hosted Loki behind a TLS ingress) and Pushgateway endpoints use HTTPS URLs. The `http_post` and Pushgateway push functions catch all exceptions and return `Error (...)` which is logged to stderr and then discarded. Setting `LOKI_URL=https://...` or `PUSHGATEWAY_URL=https://...` silently stops working with no application impact. By contrast, `kafka_service.ml` (fixed by AUDIT-029) correctly builds an HTTPS wrapper using `tls-eio` and `x509` and passes it to Cohttp_eio.

**Impact:** A startup connecting to a hosted Loki or Prometheus Pushgateway (the typical production path) receives no error at startup and no indication of the failure beyond stderr noise. All log lines from services and all metrics from `-fn` workloads are silently lost. The only observable symptom is absent data in Grafana, which may be mistaken for a configuration or labelling issue rather than a TLS connectivity problem.

**Remediation:** Apply the same TLS pattern already used in `kafka_service.ml`:

1. Factor out (or duplicate) the `tls_authenticator` lazy value and `make_https_wrapper` helper from `kafka_service.ml`. A new shared `Sun_http_tls` module in `obs-eio` would serve all three clients; alternatively, copy the pattern inline per-file.

2. In `obs_loki.ml` (line 14), replace:
   ```ocaml
   let client = Cohttp_eio.Client.make ~https:None net in
   ```
   with:
   ```ocaml
   let client = Cohttp_eio.Client.make ~https:(Some (make_https_wrapper ())) net in
   ```

3. Apply the same change in `obs_prometheus.ml` (line 242).

4. Plain `http://` URIs continue to work — Cohttp_eio only invokes the https wrapper for HTTPS scheme URIs.

5. Add tests that verify an `https://` LOKI_URL and `https://` PUSHGATEWAY_URL do not immediately raise or error before the connection attempt. The required packages (`tls-eio`, `x509`, `domain-name`, `ptime`) are already in `dune-project` and the Dockerfile template opam install line.

## Review — automated checks passed
Build clean. Tests pass. Diff confined to 4 expected files (obs_loki.ml, obs-eio-loki/lib/dune, obs_prometheus.ml, obs-eio-prometheus/lib/dune). No project/tickets/ changes. Both backends now pass ~https:(Some (Lazy.force https_wrapper)) to Cohttp_eio.Client.make. TLS wrapper uses system CA bundle via X509/tls-eio, fails closed if no bundle found. http:// URIs unaffected. All required libraries (tls-eio x509 domain-name ptime) present in both dune stanzas. Both library stanzas have (wrapped false). Pattern is consistent with kafka_service.ml.
