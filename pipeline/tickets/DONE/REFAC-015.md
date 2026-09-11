---
id: REFAC-015
type: refactor
severity: medium
source: codebase simplification review 2026-06-15
branch: REFAC-015/extract-tls-wrapper
worktree: /home/lbendtly/Code/sun-REFAC-015-extract-tls-wrapper
---

Extract shared TLS/HTTPS wrapper to eliminate three identical copy-pastes

**Depends on:** None.

**Description:**

The same ~55-line block — `tls_authenticator`, `ca_paths`, and `make_https_wrapper` — is copy-pasted verbatim into three unrelated modules:

| File | Lines |
|------|-------|
| `integrations/observability/obs-eio-loki/lib/obs_loki.ml` | 7–62 |
| `integrations/observability/obs-eio-prometheus/lib/obs_prometheus.ml` | 226–281 |
| `integrations/kafka/kafka-eio-service/lib/kafka_service.ml` | 40–97 |

Each copy defines the same four CA bundle paths, the same `X509.Certificate.decode_pem_multiple` scan, the same `X509.Authenticator.chain_of_trust` call, and the same `Tls_eio.client_of_flow` wrapper. The only difference is the `lazy` binding name.

**Remediation:**

1. Create `integrations/observability/obs-eio/lib/obs_tls.ml` (it lives here because both Loki and Prometheus already depend on `obs-eio`, and `kafka-eio-service` can add the dep without a cycle):

```ocaml
(* Shared system-CA TLS wrapper used by HTTP-push observability backends
   and any other Cohttp-eio client that needs certificate-verified HTTPS. *)

val https_wrapper :
  ([ `Https ] Eio.Net.Ty.scheme ->
   Uri.t ->
   _ Eio.Net.stream_socket_ty Eio.Resource.t ->
   Tls_eio.t)
  Lazy.t
```

The implementation is the same code that currently lives in all three files.

2. In `obs_loki.ml`, `obs_prometheus.ml`, and `kafka_service.ml`, delete the local `tls_authenticator` / `make_https_wrapper` / `https_wrapper` definitions and replace every use with `Obs_tls.https_wrapper`.

3. Add `obs-eio` to `kafka-eio-service`'s dune `libraries` stanza if not already present (check first — it may already be there via `kafka-eio-service.ml` imports).

**Acceptance criteria:**

- `obs_loki.ml`, `obs_prometheus.ml`, and `kafka_service.ml` contain no local `tls_authenticator` or `make_https_wrapper` definitions.
- `obs_tls.ml` is the single source of truth for CA bundle paths.
- `dune build` passes.
- Unit tests pass.

## Review — automated checks passed
TLS boilerplate successfully extracted to obs_tls.ml; all three consumers use Obs_tls.https_wrapper; dune build and unit tests pass
