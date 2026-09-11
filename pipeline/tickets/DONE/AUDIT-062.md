---
id: AUDIT-062
type: audit-finding
severity: medium
source: codebase review 2026-06-14
branch: AUDIT-062/auth-before-body-read
worktree: /home/lbendtly/Code/sun-AUDIT-062-auth-before-body-read
---

Authenticate routed requests before reading request bodies when possible

**Depends on:** None.

**Description:** In `framework/sun-svc/lib/service.ml`, after a route is matched, `dispatch` calls `read_body_limited` before `Auth.validate` for the route. That means unauthorized requests still have their bodies read up to `max_body_bytes`, and oversized unauthorized requests return `413` before auth is checked.

**Impact:** Protected endpoints spend I/O and memory budget on bodies from callers that should be rejected from headers alone. This also makes auth behavior less predictable because an invalid credential with a large body can receive payload-size errors instead of `401`/`403`.

**Remediation:**

1. For route auth levels that can be decided from headers, validate auth before reading the body.
2. Preserve body-size enforcement for authenticated requests.
3. Be explicit about any auth mode that genuinely needs body access in the future.
4. Add tests for unauthorized large-body requests and authenticated oversized requests.

**Acceptance criteria:**

- Invalid/missing auth on protected routes returns `401`/`403` without reading the full body.
- Authenticated oversized requests still return `413`.
- Public routes retain current body-reading behavior.
- Existing service tests continue to pass.

## Review — automated checks passed
Auth check correctly moved before body read in Found branch; all 17 service tests pass including 3 new auth_before_body cases
