---
id: REFAC-028
type: refactor
severity: high
source: codebase simplification review 2026-06-15
branch: REFAC-028/decompose-cmd-cloud
worktree: /home/lbendtly/Code/sun-REFAC-028-decompose-cmd-cloud
---

Decompose cmd_cloud.ml (843 lines, 5+ concerns) into focused sub-modules

**Depends on:** REFAC-021.

**Description:**

`cli/sun/bin/cmd_cloud.ml` is 843 lines — the largest file in the CLI — and mixes five distinct responsibilities:

| Concern | Approximate lines |
|---------|------------------|
| Tool checks, config helpers, `check_tool` | 1–50 |
| Terraform init/plan/apply lifecycle | 51–400 |
| ECR registry push (`push_image`) and `git_sha` | 500–560 |
| `sun cloud deploy` orchestration (tf + push + render) | 561–680 |
| Secret management (`sun cloud secret`) | 681–843 |

These concerns have no shared state — they are separate subcommands bolted together in one file. Navigation requires scrolling through hundreds of lines to find any one feature.

REFAC-021 extracts `state_dir` first; REFAC-020 extracts `git_sha`; REFAC-022 extracts `check_tool`. After those land, `cmd_cloud.ml` is still 800+ lines.

**Remediation:**

Split into:

1. **`cmd_cloud_tf.ml`** — Terraform init/plan/apply helpers. Functions: `tf_init`, `tf_plan`, `tf_apply`, `render_plan_output`, and related.
2. **`cmd_cloud_registry.ml`** — ECR/registry operations: `push_image`, `ecr_login`, image tag resolution.
3. **`cmd_cloud_secret.ml`** — `sun cloud secret set/get/list` handlers.
4. **`cmd_cloud.ml`** — Keep only the top-level `Cmdliner` term definitions that dispatch to the above modules (~80 lines).

No public API changes. This is a pure file split within `cli/sun/bin/`.

**Acceptance criteria:**

- `cmd_cloud.ml` is ≤100 lines after the split.
- Each sub-module file has a single clear responsibility.
- `dune build` passes.
- `sun cloud tf-plan`, `sun cloud deploy`, and `sun cloud secret` all behave identically.
