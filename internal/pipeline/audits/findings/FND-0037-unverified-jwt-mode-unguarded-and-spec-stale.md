# FND-0037 — `Unverified_dev_only` JWT mode has no runtime guard, and the `sol-svc` spec still steers to it

- **Classification:** `DESIGN_GAP` (the runtime guard) + `DOCUMENTATION_GAP` (the spec)
- **State:** `FIXED_UNQUALIFIED` (DOCS-021 corrected the spec; SEC-006, 2026-09-24, refuses the mode at startup without an explicit opt-in that only `sol up` renders)
- **First identified:** 2026-09-23, correctness audit
- **Last verified:** 2026-09-23 (`origin/main @ f3e9480b`)
- **Derived ticket:** `DOCS-021` (spec), `SEC-006` (runtime guard)
- **Evidence class:** `STATIC`

## What is established

`Auth.jwt_verification = Verified_signature_required of … | Unverified_dev_only`
(`sol-svc/lib/auth.ml`). `Unverified_dev_only` base64-decodes the payload and checks
only `exp` and scopes (`auth_internal.ml:134-143`), so any caller can mint a token with
any `sub` and scopes. The constructor's name is the only thing that says "dev". No
code consults the environment, the profile or the deploy target, so a service built
with it accepts forged tokens in production. SEC-003 kept the mode deliberately as an
*"explicit, clearly-named local-dev-only escape"*. It did not add a guard.

The spec makes this worse (`framework/ocaml/sol-svc/sol-svc.md`):

- `:714` — the "full example" protects `POST /payments/charge` with
  `` `Jwt { scopes = ["write:payments"]; verification = Unverified_dev_only } ``.
- `:734-735` — "Out of Scope (v1)": *"JWT signature verification —
  `Unverified_dev_only` is the v1 local-development mode; `Verified_signature_required`
  triggers a 501 until v2 JWKS verification is implemented."* This is false:
  `validate_verified_jwt` (`auth_internal.ml:278-299`) implements HS256, static JWKS
  and fetched JWKS, and enforces issuer and audience.

A reader following the spec concludes that unverified is the only working JWT mode and
copies it onto a payments route.

## Impact

High. The failure is an authentication bypass, reachable by following the package's
own documentation.

## Decision needed (guard)

Options: refuse `Unverified_dev_only` at `Service.Make.run` unless an explicit opt-in
env var is set, which `sol deploy` never renders for a profile target; or have
`sol deploy`/`sol check` detect it (it is a source-level constructor, so only a runtime
check is reliable). Recording the decision is the work; the spec fix is not blocked on it.

## Related

SEC-003 (verified JWT implementation); CODEX_STYLE_AUDIT-024 (the constructor rename).
