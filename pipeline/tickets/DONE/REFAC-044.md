---
id: REFAC-044
type: refactor
branch: REFAC-044/deduplicate-tls-loader
worktree: ../sun-REFAC-044-deduplicate-tls-loader
severity: high
source: codebase simplification review 2026-06-16
---

Deduplicate TLS CA-bundle loader shared by Loki and Prometheus backends

**Depends on:** None.

**Description:**

`obs-eio-loki/lib/obs_loki.ml` (lines 7–62) and `obs-eio-prometheus/lib/obs_prometheus.ml` (lines 224–281) contain a character-for-character copy of the same ~55-line block:

- `tls_authenticator` — lazy CA-bundle reader that probes 4 system certificate paths
- `make_https_wrapper` — builds a `Cohttp_eio.Client` TLS wrapper from the authenticator
- `https_wrapper` — lazy value exposing the wrapper

The only difference is the error-message prefix string (`"obs-loki"` vs `"obs-prometheus"`). Any future change to CA-path discovery, TLS config, or SNI handling must be applied in two places and kept in sync.

**Remediation:**

1. Create `integrations/observability/obs-eio/lib/obs_tls.ml` (new private module inside the existing `obs-eio` library) with a single public value:
   ```ocaml
   val https_wrapper : (Uri.t -> _ Eio.Flow.two_way -> Tls_eio.t) Lazy.t
   ```
2. Export it in the `obs-eio` library's `dune` file (it is already a dependency of both backends).
3. In `obs_loki.ml` and `obs_prometheus.ml`, replace the ~55-line block with `let https_wrapper = Obs_tls.https_wrapper`.
4. Remove the now-unused `X509` / `Ca_certs` opens from both files if they were only used by the deleted block.

**Acceptance criteria:**

- `grep -rn "tls_authenticator\|make_https_wrapper" integrations/observability/obs-eio-loki integrations/observability/obs-eio-prometheus` returns zero hits.
- `dune build integrations/observability/` passes.
- `dune test integrations/observability/` passes.

## Review — automated checks passed
TLS CA-bundle loader and https_wrapper extracted to obs_tls.ml; both obs_loki.ml and obs_prometheus.ml delegate to Obs_tls.https_wrapper; build clean; no duplication remains
