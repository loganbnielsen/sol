---
id: CODE_LAYER-024
type: refactor
severity: medium
title: Load a checked PR inventory once per pipeline operation
source: internal/pipeline/audits/2026-09-28_code_layer_audit.md
---

Load a checked PR inventory once per pipeline operation

**Depends on:** None.

**Premise verified (2026-09-28):** Read the implementation at `internal/tooling/soldev/lib/soldev_merge.ml:36-59,587-659` and its representative callers/tests on origin/main `6a7b1fb5`. The described boundary remains present.

## Problem

open_prs uses output_shell, discarding exit status and stderr. Authentication/network failure becomes an empty list, so merge reports success with no PRs. Listing also fetches the complete PR inventory for each READY ticket, multiplying remote calls and mixing snapshots.

## Remediation

Return a typed Result from a checked gh argv invocation and decode it at the adapter boundary. Resolve the inventory once per operation, then do local ticket lookups; propagate failed inventory retrieval rather than treating it as empty.

## Acceptance criteria

- A failing gh stub yields nonzero status with its diagnostic; a successful [] response yields an empty inventory. Listing multiple READY tickets invokes gh pr list once and retains correct per-ticket annotations.
- Update a runnable example/demo for application-facing behavior, or record why this is an internal-only refactor.
- Record the per-language capability verdict for framework/application contracts, or explain why language parity is unaffected.
