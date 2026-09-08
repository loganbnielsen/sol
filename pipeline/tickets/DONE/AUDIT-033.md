---
id: AUDIT-033
type: audit-finding
severity: high
source: project/audits/2026-06-12e_homemade_code_audit.md
---

Replace ad hoc `sun.toml` parser with a maintained TOML package

**Depends on:** None.

**Description:** `cli/sun/lib/sun_cli_toml.ml` is a custom line-oriented TOML parser built from `String.sub`, delimiter searches, and section-state mutation. It only supports the subset Sun originally needed, silently ignores many malformed shapes, and implements inline table/list parsing by hand.

**Impact:** `sun.toml` is user-facing configuration. A partial parser can misread valid TOML, silently drop settings, reject reasonable formatting, or behave differently from user expectations. This is especially risky for deployment settings such as secret keys, labels, rollout strategy, ingress, and resource sizing.

**Remediation:**
1. Replace the parser internals with a maintained TOML package available in opam, preferably `otoml` or `toml`.
2. Preserve the existing `Sun_cli_toml.t` type and `load : string -> t` API unless a narrowly scoped interface improvement is required.
3. Keep current validation behavior for reserved labels, rollout strategies, canary weights, and pause durations.
4. Stop silently accepting malformed TOML for fields Sun owns; return or raise clear `sun.toml:` errors consistent with current validation errors.
5. Add coverage for standard TOML formatting that the current parser cannot handle safely: multiline whitespace, quoted keys, inline tables, arrays, comments, and reordered sections.
6. Update `dune-project` and `cli/sun/lib/dune` with the selected TOML dependency.
7. Run `eval $(opam env) && dune test cli/sun/test`.

## Review — automated checks passed
otoml replacement complete — hand-rolled parser fully removed, all fields preserved, Parse_error on bad input, sun.dev/ guard intact, canary steps correct, tests pass
