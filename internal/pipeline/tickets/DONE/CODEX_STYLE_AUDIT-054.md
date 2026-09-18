---
id: CODEX_STYLE_AUDIT-054
type: refactor
severity: medium
source: style audit
---

Type hosted cost attribution provider, resource kind, billing period, and currency.

**Depends on:** none.

**Problem:** `cli/sun/lib/sun_cli_hosted_model.ml:58-71` stores cost attribution
domains such as `provider`, `resource_kind`, `billing_period`, and `currency` as
strings. Only currency is validated later.

**Goal:** Make billing/cost metadata domains explicit.

**Acceptance criteria:**

- Add variants or validated wrappers for provider, resource kind, billing period,
  and currency.
- Move parsing/validation into constructors.
- Preserve JSON output strings.

Completion: hosted cost attribution now uses abstract validated wrappers for
billing period, provider, resource kind, and currency while public constructors
continue to parse string inputs. JSON rendering explicitly converts typed values
back to strings, focused invalid-input and JSON stability tests pass, and the
affected CLI build plus hosted executor compatibility tests pass. No baseline
changes accepted.
