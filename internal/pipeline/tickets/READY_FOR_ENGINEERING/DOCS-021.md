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
