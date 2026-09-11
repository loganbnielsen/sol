---
id: CODEX_STYLE_AUDIT-055
type: refactor
severity: medium
source: style audit
---

Validate hosted URL and custom domain inputs with refined types.

**Depends on:** none.

**Problem:** `cli/sun/lib/sun_cli_hosted_url.ml` constructs default URLs and DNS
records from raw strings, and `dns_record.ttl` is a bare int. Empty or invalid
domain segments are normalized to `"unknown"` instead of rejected.

**Goal:** Make DNS and URL generation accept validated domain inputs.

**Acceptance criteria:**

- Add validated DNS label/domain and positive TTL types.
- Reject invalid default URL inputs at construction time.
- Keep JSON output unchanged for valid records.

Completion: hosted URL generation now validates DNS labels/domains and returns
typed `Result` failures instead of falling back to `unknown`; custom-domain DNS
records use validated domains and positive TTLs. Hosted executor propagates
invalid default URL construction errors, valid DNS JSON output is unchanged, and
focused hosted URL/executor tests plus the affected CLI build pass. No baseline
changes accepted.
