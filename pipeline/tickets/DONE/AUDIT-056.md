---
id: AUDIT-056
type: audit-finding
severity: high
source: codebase review 2026-06-14
branch: AUDIT-056/jwt-verification-library
worktree: /home/lbendtly/Code/sun-AUDIT-056-jwt-verification-library
---

Implement production JWT verification with a maintained JOSE/JWT library

**Depends on:** None.

**Description:** `framework/sun-svc/lib/auth.ml` manually base64url-decodes JWT payloads, parses JSON claims, checks `exp`, and checks scopes. Signature verification is explicitly disabled unless the route opts into `allow_unverified_v1_unsafe = true`; otherwise JWT auth returns `501 Not Implemented`.

**Impact:** Sun services cannot use production JWT auth safely today. The handwritten parsing path only validates unsigned claims, so enabling it is intentionally unsafe. Leaving verification unimplemented also means route authors may choose the unsafe flag to unblock development and accidentally ship it.

**Remediation:**

1. Integrate a maintained JOSE/JWT verification library available in the OCaml ecosystem, or add a narrow verified-token adapter around one.
2. Support configured issuers, audiences, algorithms, and JWKS/key material.
3. Keep `allow_unverified_v1_unsafe` only as a clearly deprecated local-dev escape hatch.
4. Add tests with valid signed tokens, invalid signatures, wrong issuer/audience, expired tokens, missing scopes, and key rotation/JWKS failure cases.

**Acceptance criteria:**

- `Auth.validate` can verify signed JWTs without `allow_unverified_v1_unsafe = true`.
- Invalid signatures are rejected even when payload claims look valid.
- Existing public/API-key auth tests continue to pass.
- Documentation and examples steer users to verified JWT configuration, not unsafe v1 behavior.

## Review — automated checks passed
AUDIT-056 fully implements HS256 JWT signature verification using digestif. Build is clean, all 35 tests pass (18 auth + 17 service). Implementation covers: header parsing and alg validation, constant-time HMAC-SHA256 comparison, secret resolution from config or SUN_JWT_SECRET env var, expiry check, scope check. allow_unverified_v1_unsafe is preserved as a deprecated escape hatch that emits a stderr warning. project/tickets/ is not touched in the diff.
