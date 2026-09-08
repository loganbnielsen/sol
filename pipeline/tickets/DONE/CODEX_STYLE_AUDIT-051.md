---
id: CODEX_STYLE_AUDIT-051
type: refactor
severity: medium
source: style audit
---

Return Result from scaffold domain/name parsing instead of exiting in helpers.

**Depends on:** none.

**Problem:** `cli/sun/lib/sun_cli_cmd_new.ml:130-138` parses `"domain/name"` and
calls `exit 1` from a helper. This hides failure in control flow instead of the
type and makes the parser hard to test independently.

**Goal:** Make scaffold argument parsing typed and testable.

**Acceptance criteria:**

- Change `parse_domain_name` to return `(domain * name, string) result`.
- Keep process exit at the command boundary.
- Add tests for malformed names.

Completion: `parse_domain_name` now returns a typed `Result`, command handlers
exit through `domain_name_or_exit`, malformed names are covered in scaffold
tests, and focused scaffold tests plus the affected CLI build pass. No baseline
changes accepted.
