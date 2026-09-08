---
id: REFAC-006
branch: REFAC-006/shared-tls-helper
worktree: /home/lbendtly/Code/sun-REFAC-006-shared-tls-helper
type: refactor
severity: medium
source: codebase simplification review 2026-06-15
---

Extract shared TLS / HTTPS wrapper into a common `Sun_tls` library

**Depends on:** None.

**Description:**

The same ~60-line TLS helper — CA bundle discovery, authenticator construction, and `Cohttp_eio` HTTPS wrapper — is copy-pasted verbatim across three packages:

| File | Lines | Error prefix |
|------|-------|--------------|
| `integrations/observability/obs-eio-loki/lib/obs_loki.ml` | 1–62 | `"obs-loki:"` |
| `integrations/observability/obs-eio-prometheus/lib/obs_prometheus.ml` | 224–281 | `"obs-prometheus:"` |
| `integrations/kafka/kafka-eio-service/lib/kafka_service.ml` | 38–97 | `"kafka_service:"` |

The copies are structurally identical — the only difference is the error-message prefix. Searching for CA bundle paths (`/etc/ssl/certs/ca-certificates.crt`) or updating the list of distro paths currently requires three separate edits.

**Remediation:**

1. Create a new library `integrations/common/sun-tls/` with:
   - `lib/dune` declaring `(library (name sun_tls) (wrapped false) (libraries tls tls-eio x509 ptime cohttp-eio))`
   - `lib/sun_tls.ml` exposing:
     ```ocaml
     (* Returns an HTTPS wrapper suitable for Cohttp_eio.Client.make.
        ~caller is used in error messages, e.g. "obs-loki". *)
     val make_https_wrapper : caller:string ->
       (Uri.t -> _ -> Tls_eio.flow) Lazy.t
     ```
     Implement by lifting the shared CA-bundle discovery and `Tls_eio.client_of_flow` wiring out of the three files. Keep the same lazy initialisation and fail-closed semantics.
2. Add `sun-tls` as a dune dependency in:
   - `integrations/observability/obs-eio-loki/lib/dune`
   - `integrations/observability/obs-eio-prometheus/lib/obs_prometheus.ml`'s dune file
   - `integrations/kafka/kafka-eio-service/lib/dune`
3. In each of the three files, delete the `tls_authenticator`, `make_https_wrapper`, and `https_wrapper` definitions and replace with:
   ```ocaml
   let https_wrapper = Sun_tls.make_https_wrapper ~caller:"obs-loki"
   (* etc. *)
   ```
4. Run `dune build` and confirm no new warnings.

**Acceptance criteria:**

- CA bundle path list exists in exactly one place.
- `obs_loki.ml`, `obs_prometheus.ml`, and `kafka_service.ml` each contain no local `tls_authenticator`/`make_https_wrapper`/`https_wrapper` definitions.
- `dune build` passes.
- Existing HTTPS connectivity (Loki push, Prometheus Pushgateway, schema registry) is unaffected.

## Review — automated checks passed
CA bundle path list consolidated into sun_tls library; all three consumers delegate to Sun_tls.make_https_wrapper; (wrapped false) set; dune build clean; project/tickets/ untouched
