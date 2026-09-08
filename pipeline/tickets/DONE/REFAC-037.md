---
id: REFAC-037
type: refactor
severity: medium
source: codebase simplification review 2026-06-15
branch: REFAC-037/workspace-scan-module
worktree: /home/lbendtly/Code/sun-REFAC-037-workspace-scan-module
---

Decompose sun_cli_deployment_plan.ml (430 lines) — separate discovery from plan construction

**Depends on:** REFAC-035.

**Description:**

`cli/sun/lib/sun_cli_deployment_plan.ml` at 430 lines mixes three concerns:

| Concern | Lines | Description |
|---------|-------|-------------|
| Data types | 1–45 | `primitive`, `mode`, `service_spec`, `t`, `canary_step`, etc. |
| Discovery / workspace scanning | 46–273 | `prim_of_manifest`, `k8s_name_of`, `namespace_of`, `discover_schema_subjects`, `discover_topics`, `discover_migrations`, `derive_consumer_groups` |
| Plan construction + rendering | 274–430 | `of_services`, `render_spec`, `image_ref`, `pp_summary`, serialization (`to_json`, `canary_step_to_json`, etc.) |

The discovery functions (`discover_*`, 176–273) scan the filesystem and are called only during `of_services`. The rendering functions (`render_spec`, `pp_summary`, serialization) are called from CLI commands that have an already-constructed plan and never touch the filesystem.

After REFAC-035 lands (which extracts a `fold_dir` helper), the discovery functions will be cleaner but still in the same file.

**Remediation:**

Extract the discovery + workspace-scanning functions (lines 176–273) into a new `sun_cli_workspace_scan.ml`:
- `discover_schema_subjects`
- `discover_topics`  
- `discover_migrations`
- `derive_consumer_groups`

Keep the data types and plan construction/rendering in `sun_cli_deployment_plan.ml` (~230 lines after split). `of_services` calls into `Sun_cli_workspace_scan.*`.

**Acceptance criteria:**

- `sun_cli_deployment_plan.ml` is ≤250 lines.
- `sun_cli_workspace_scan.ml` contains no serialization, rendering, or JSON logic.
- `dune build` passes.
- `sun up` plan output is unchanged.
