---
id: DOCS-021
type: bug
severity: high
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

Correct the `sol-svc` spec: JWT verification is implemented, and the payments example must not use `Unverified_dev_only`

**Depends on:** None.

**Finding:** FND-0037 (`internal/pipeline/audits/findings/`).

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding for the command/probe and observed output).

## Problem

`framework/ocaml/sol-svc/sol-svc.md` says `Verified_signature_required` "triggers a 501 until v2 JWKS verification is implemented" (false — `validate_verified_jwt` implements HS256/JWKS with issuer/audience checks), and its full example protects `POST /payments/charge` with `Unverified_dev_only`, an authentication bypass if copied.

## Remediation

Rewrite the Out-of-Scope entry and the full example to use `Verified_signature_required`; describe `Unverified_dev_only` only as a local-development mode with an explicit warning. The runtime guard is a separate decision recorded in FND-0037.

## Acceptance criteria

- No example in `sol-svc.md`, `docs/`, or tutorial code uses `Unverified_dev_only` outside a clearly-labelled local-dev snippet.
- The Out-of-Scope list no longer claims verification is unimplemented.
- Demo/example: docs-only; no demo change applies.

## Completion notes

- `framework/ocaml/sol-svc/sol-svc.md`:
  - The full example protects `/payments/charge` with `Verified_signature_required`
    (issuer, audience, `RS256`, `Jwks_url`). It no longer uses `Unverified_dev_only`.
  - The `Unverified_dev_only` section now opens with a warning: no signature check, any
    caller can mint any token, local development only, with a pointer to SEC-006.
  - The Out-of-Scope claim that verification "triggers a 501 until v2" is gone, and so
    is the "v2 not ready → 501" line in the request-flow diagram. Two real limitations
    replace it, both verified in code: an unknown `kid` stays rejected until the 5-minute
    JWKS cache expires (`auth_internal.ml` `jwks_ttl_s`); and a token without `exp` is
    accepted (`jose` `Jwt.check_expiration`: `None -> Ok t`).
- Same file, other statements that led readers to write wrong code (found by
  compiling the example):
  - The example did not compile. `open Sol_svc` names no module (the library is
    `(wrapped false)`), and `Service.Make(H).run` is not valid OCaml. It now uses
    `module S = Service.Make (H)` and handles `run`'s result. It was compile-checked in a
    throwaway dune executable against `sol-svc`/`sol-obs` (rc=0, not committed).
  - The "Why `(wrapped true)`" / `sol_svc.ml` entry-point section, the `Sol_svc.` module
    prefixes, the `http/` package layout, and the dune snippet described a structure that
    does not exist. They now match `framework/ocaml/sol-svc/`.
  - The test snippet used `~obs` and the invalid functor syntax.
  - `SOL_API_KEY_FILE` was documented as "read on every validation", but
    `Service.api_key_reader` reads it once at startup. The doc now says rotation requires
    a restart.
- Review round 1 (non-blocking, taken): the error table and flow diagram described a
  missing API key as a request-time 500. `api_key_reader` makes it a startup `Config`
  error, so both now say so. The diagram's 500 is kept, relabelled for its real cause
  (JWKS unavailable).
- Demo/example: docs-only. The compile-check above covers the spec's example.
- Language parity: no language-parity impact (OCaml package spec only).
