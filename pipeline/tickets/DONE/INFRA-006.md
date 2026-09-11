---
id: INFRA-006
type: feature
severity: low
source: CODE_LAYER-021 pre-commit hook drift, 2026-09-09
---

Add a CI guardrail for `dune fmt` drift.

**Problem:** During CODE_LAYER-021, running `dune fmt` locally promoted formatting changes across many unrelated `dune` files. Because CI does not currently check formatting drift, tracked files can drift from the formatter until a local hook or manual run surfaces a noisy repo-wide diff in an unrelated PR.

**Goal:** Add a CI check that fails when `dune fmt` would change tracked files, without promoting or committing those changes during the check.

**Acceptance criteria:**

- `.github/workflows/ci.yml` runs a formatting check in PR CI.
- The check detects both OCaml and dune-file formatter drift covered by `dune fmt`.
- The CI command is non-mutating from the repository's perspective: if formatting differs, the job fails and prints a useful diff/status instead of silently promoting files.
- Existing formatter drift is cleaned up as part of the implementation path so the new CI check starts green.
- Document any local prerequisite if the check needs a tool that is not already installed by the existing OCaml dependency setup.
