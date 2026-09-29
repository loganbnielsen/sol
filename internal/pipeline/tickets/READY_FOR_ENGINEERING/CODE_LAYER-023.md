---
id: CODE_LAYER-023
type: refactor
severity: high
title: Drain both subprocess output streams through the existing argv runners
source: internal/pipeline/audits/2026-09-28_code_layer_audit.md
---

Drain both subprocess output streams through the existing argv runners

**Depends on:** None.

**Premise verified (2026-09-28):** Read the implementation at `internal/tooling/sol_process/lib/sol_process.ml:131-139 and cli/lib/base/sol_cli_process.ml:282-295` and its representative callers/tests on origin/main `6a7b1fb5`. The described boundary remains present.

## Problem

Both shell runners drain stdout to EOF before reading stderr. A child that fills stderr blocks before closing stdout, deadlocking the parent. Soldev PR creation and local service build commands use these paths.

## Remediation

Delegate shell execution to the existing argv runner with sh -c, preserving trimming, status and error contracts. Keep concurrency/capture logic in one implementation per runner.

## Acceptance criteria

- A child writing at least 256 KiB to stderr before stdout completes through both shell APIs; stdout, stderr and nonzero exit remain intact. Use a bounded regression test and argv positive control.
- Update a runnable example/demo for application-facing behavior, or record why this is an internal-only refactor.
- Record the per-language capability verdict for framework/application contracts, or explain why language parity is unaffected.
