---
id: CODEX_STYLE_AUDIT-034
type: refactor
severity: medium
source: style audit
---

Type Loki stream label selection instead of passing raw label-name strings.

**Depends on:** CODEX_STYLE_AUDIT-032.

branch: CODEX_STYLE_AUDIT-034/loki-label-selection
worktree: /home/lbendtly/Code/sun-CODEX-034

**Problem:** `integrations/observability/obs-eio-loki/lib/obs_loki.ml:188-206`
accepts `?(label_names = [])` as raw strings and looks them up in ambient
context. A typo silently omits the intended label.

**Goal:** Make Loki label selection validated and self-documenting.

**Acceptance criteria:**

- Use the validated label-name type from the observability metric work.
- Consider returning a warning or error for requested labels missing from
  context.
- Update Loki tests to cover label selection.

## Review — automated checks passed
Implementation satisfies CODEX_STYLE_AUDIT-034: Loki label selection now uses typed Obs_loki.stream_label values backed by validated Obs.label_name, invalid selectors raise before backend creation, missing selected context labels are warned and omitted, call sites/docs were updated, and focused obs-eio/obs-eio-loki tests plus dune build passed. No baseline changes accepted.
