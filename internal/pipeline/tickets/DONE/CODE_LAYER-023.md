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

## Completion (2026-09-29)

- **Premise re-verified** at origin/main `788e688d`: `Sol_cli_process.run_shell` drained stdout with `In_channel.input_all` before touching stderr; `Sol_process.run_shell` did the same. Both paths were reached by `soldev pipeline submit` (PR creation), `sol local up` build steps, and the temporary port-forward launcher.
- **Fix.** `Sol_cli_process.run_shell` and `Sol_process.run_shell` now delegate to the argv runner via `sh -c`, keeping one concurrent capture implementation per runner. Trimming, exit status, and the `(output, error) result` / `status` contracts are unchanged; the raw command is still echoed before delegation.
- **Bounded regression tests** (Alcotest, `SIGALRM` guard so a regression fails instead of hanging): `head -c 262144 /dev/zero >&2; echo done` completes through `run_shell` and, as the argv positive control, through `run`. The child blocks once the 64 KiB pipe fills, which is exactly the deadlock the audit reproduced (`shell` exit 124 under `timeout 3s`); both new tests fail by timeout against the previous implementation.
- Validation: full `dune build`; `test_process.exe` 23/23 and `test_sol_process.exe` 23/23 pass; `dune fmt --preview` clean; no-comments policy holds (no comments added).
- **Demo/example: not applicable** — internal tooling and CLI subprocess plumbing, no app-author surface. No language-parity impact: no framework or application contract changes.
