---
id: CODEX_STYLE_AUDIT-049
branch: CODEX_STYLE_AUDIT-049/refined-toml-fields
worktree: /home/lbendtly/Code/sun-CODEX-049
type: refactor
severity: medium
source: style audit
---

Use refined resource quantity and ingress path types in `sun.toml`.

**Depends on:** CODEX_STYLE_AUDIT-048.

**Problem:** `Sun_cli_toml.t` stores `cpu`, `memory`, `ingress_host`, and
`ingress_path` as raw strings. Invalid Kubernetes quantities or ingress paths
compile and travel deep into YAML rendering.

**Goal:** Validate resource and ingress fields at TOML parse time.

**Acceptance criteria:**

- Add validated types for CPU quantity, memory quantity, hostname, and path.
- Convert to strings only in manifest rendering.
- Add tests for invalid quantities and invalid ingress paths.

## Review — automated checks passed
Validated types for cpu_quantity, memory_quantity, hostname, and ingress_path introduced in sun_cli_toml.ml; parsing validates at load time; to_string called at manifest boundary; four new tests cover all invalid-input cases; all 200+ tests pass; no project/tickets/ touched; wrapped false preserved.
