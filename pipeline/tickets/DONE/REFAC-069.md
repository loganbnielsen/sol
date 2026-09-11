---
id: REFAC-069
type: refactor
severity: high
source: cross-cutting-design-review 2026-08-31
branch: refac-068-070-cleanup
worktree: none (direct main-checkout branch, no linked worktree)
pr: https://github.com/loganbnielsen/sun/pull/65
---

Hide `sun-svc` auth validation transport internals

**Depends on:** REFAC-067.

## Problem

`Auth.validate` and `Auth.fetch_jwks_over_https` are service internals but are
currently exported in `auth.mli`. The direct auth tests depend on them because
they exercise JWT verification without spinning up a service.

## Goal

Keep `Auth` focused on public policy/context types while preserving strong auth
coverage through either black-box service tests or a deliberate private test
module.

## Acceptance criteria

- `Auth.validate` is no longer normal user-facing API.
- `Auth.fetch_jwks_over_https` is no longer normal user-facing API.
- Verified JWT tests still cover HS256, RS256/JWKS, bad signatures, issuer,
  audience, expiry, scopes, and JWKS fetch failure.
- `Service.Make` remains the only production caller of auth validation.
