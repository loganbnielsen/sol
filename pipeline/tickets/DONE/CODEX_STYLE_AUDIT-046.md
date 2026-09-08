---
id: CODEX_STYLE_AUDIT-046
type: refactor
severity: medium
source: style audit
branch: codex/style-audit-046
worktree: /home/lbendtly/Code/sun-CODEX-046
---

Pass deployment render inputs as a typed spec instead of a long labeled argument list.

**Depends on:** none.

**Problem:** `cli/sun/lib/sun_cli_deployment_render.ml:5-8` takes a large set of
labeled arguments: namespace, k8s name, primitive, spec image, config, secrets,
schedule, replicas, CPU, memory, rollout, ingress, labels, and progressive
delivery. Labels help, but the function still permits invalid cross-field states.

**Goal:** Render from a typed spec that encodes workload constraints.

**Acceptance criteria:**

- Introduce a render spec record or variant keyed by service, worker, and
  function workloads.
- Move schedule requirements into the `Render_fn` variant.
- Update `Sun_cli_deployment_plan.render_spec` to construct the spec.

## Review — automated checks passed

Focused deployment plan and manifest render tests pass. Deployment rendering now
accepts a typed spec with common fields plus service/worker/function workload
variants, and `Render_fn` carries the resolved schedule.
