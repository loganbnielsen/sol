---
id: CODEX_STYLE_AUDIT-004
type: refactor
severity: high
source: style audit
branch: CODEX_STYLE_AUDIT-004/workload-shape-type
worktree: ../sun-CODEX-004
---

Replace manifest renderer boolean flags with workload capability variants.

**Depends on:** none.

**Problem:** `cli/sun/lib/sun_cli_manifest.mli:36` and
`cli/sun/lib/sun_cli_manifest.mli:41` expose `ports:bool -> probes:bool` on
`deployment_doc` and `rollout_doc`. Callers in
`cli/sun/lib/sun_cli_manifest_yaml.ml:536-555` derive both booleans from
`svc.prim`, so the API allows invalid combinations such as probes without ports.

**Goal:** Represent manifest capabilities as a typed workload shape instead of
two independent booleans.

**Acceptance criteria:**

- Introduce a variant or record such as `{ expose_http; health_probes }` with
  named fields, or `Http_service | Background_worker`.
- Update `deployment_doc` and `rollout_doc` signatures and all call sites.
- Keep optional arguments followed by a trailing `()` where appropriate.
- Add tests that cover service, worker, and rollout rendering.

## Review — automated checks passed
workload_shape variant type correctly replaces ports:bool/probes:bool on deployment_doc and rollout_doc; build clean, all call sites updated, four tests cover both shapes for both functions
