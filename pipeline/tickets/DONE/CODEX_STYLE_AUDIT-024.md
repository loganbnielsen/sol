---
id: CODEX_STYLE_AUDIT-024
type: refactor
severity: high
source: style audit
branch: CODEX_STYLE_AUDIT-024/jwt-verification-mode
worktree: /home/lbendtly/Code/sun-CODEX-024
---

Replace `allow_unverified_v1_unsafe` boolean with an explicit JWT verification mode.

**Depends on:** none.

**Problem:** `framework/sun-svc/lib/auth.ml:2-5` exposes
`allow_unverified_v1_unsafe : bool`. This is a high-risk boolean trap in an auth
API: `true` disables signature verification, and a call site has to remember what
the flag means.

**Goal:** Make unsafe JWT behavior impossible to enable accidentally.

**Acceptance criteria:**

- Replace the boolean with a variant such as `Verified of verifier_config` or
  `Unverified_dev_only`.
- Make unsafe mode visually explicit at call sites and in tests.
- Preserve current behavior for existing tests by updating them to the explicit
  constructor.

## Review — automated checks passed
Focused auth/service tests pass. The boolean trap is replaced by explicit jwt_verification constructors, unsafe call sites now use Unverified_dev_only, and existing HTTP behavior is preserved.

## Merge note — perf-gate exception

Implementation commit `7383181` was applied directly after the original merge
was reverted for an e2e timing spike. Full functional suites passed, but the
full-run e2e wall-clock sample exceeded the performance threshold. Isolated e2e
runs immediately before and after the full run stayed within baseline
(`1.17s-1.19s` vs baseline `1.162s`), and independent review confirmed the JWT
refactor is not on the local-demo `~auth:\`Public` e2e path.

No performance baseline reset was accepted. This ticket is treated as done with
a documented harness/order-noise exception.
