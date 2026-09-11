---
id: REFAC-001
type: refactor
severity: medium
source: codebase simplification review 2026-06-13
branch: REFAC-001/eio-http-client
worktree: /home/lbendtly/Code/sun-REFAC-001-eio-http-client
---

Extract shared TLS/HTTPS client into a reusable `Eio_http` module; currently copy-pasted verbatim across two packages

**Depends on:** None.

**Description:**

`kafka_service.ml:38-97` and `obs_loki.ml:1-62` contain an identical 60-line block: a lazy TLS authenticator that walks a platform CA-bundle path list, a `make_https_wrapper` function that builds a certificate-verified Tls_eio client, and a `lazy https_wrapper` value. Only the error message strings differ (the module name prefix). Any fix, CA path addition, or TLS config change must be applied twice and risks diverging silently.

Both modules then call `Cohttp_eio.Client.make` and wrap requests with `Eio.Time.with_timeout_exn`. That HTTP-dispatch layer is independent but closely related.

**Remediation:**

1. Create a new library `integrations/observability/obs-eio-http/lib/` (or place in `obs-eio` directly if the extra package is not worth it) with module `Eio_http`:
   - `val tls_authenticator : (X509.Authenticator.t, string) result Lazy.t`
   - `val make_https_wrapper : unit -> (Uri.t -> Eio.Net.stream_socket_ty Eio.Resource.t -> Tls_eio.t)`
   - `val https_wrapper : (Uri.t -> Eio.Net.stream_socket_ty Eio.Resource.t -> Tls_eio.t) Lazy.t`
   - Optionally: `val post : net:_ -> clock:_ -> url:string -> body:string -> headers:Cohttp.Header.t -> (Cohttp.Response.t * string, string) result`
2. Remove the duplicate blocks from `kafka_service.ml` and `obs_loki.ml`; import from the shared module.
3. Update `sun.opam` and the relevant `dune` files to add the new library as a dependency where needed.

**Acceptance criteria:**

- `kafka_service.ml` and `obs_loki.ml` no longer contain `tls_authenticator` or `make_https_wrapper` definitions.
- The shared CA-bundle path list exists in exactly one place.
- `dune build` and all existing tests pass.

## Review — automated checks passed
Refactor successfully extracts duplicated TLS/HTTPS block into shared Eio_http module; build passes, tests pass, all acceptance criteria met
