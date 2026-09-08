---
id: CODEX_STYLE_AUDIT-025
type: refactor
severity: medium
source: style audit
branch: codex/style-audit-025
worktree: /home/lbendtly/Code/sun-CODEX-025
---

Flatten JWT validation parsing into typed Result helpers.

**Depends on:** CODEX_STYLE_AUDIT-024.

**Problem:** `framework/sun-svc/lib/auth.ml:93-142` validates Bearer tokens with
deeply nested matches over headers, token segments, base64 decoding, JSON parsing,
expiry, scopes, and subject extraction.

**Goal:** Make the JWT happy path linear and make each failure mode explicit.

**Acceptance criteria:**

- Extract helpers for bearer extraction, token splitting, payload decoding, JSON
  parsing, expiry check, and required-scope validation.
- Use Result binding for the sequential validation path.
- Preserve existing error variants and HTTP behavior in `Service`.

## Review — automated checks passed

Focused `framework/sun-svc` tests pass. The JWT validation flow is now linear
through typed Result helpers for bearer extraction, token splitting, payload
decoding/parsing, expiry, scope validation, and subject extraction. Existing
error variants and Service HTTP behavior are preserved.
