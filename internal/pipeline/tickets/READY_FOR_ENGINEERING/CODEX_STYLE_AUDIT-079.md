---
id: CODEX_STYLE_AUDIT-079
type: refactor
severity: medium
title: Validate job timing configuration before entering the runtime
source: internal/pipeline/audits/2026-09-28_code_layer_audit.md
---

Validate job timing configuration before entering the runtime

**Depends on:** None.

**Premise verified (2026-09-28):** Read the implementation at `framework/ocaml/sol-jobs/lib/sol_jobs.ml:32-48,225-243 and claim_q` and its representative callers/tests on origin/main `6a7b1fb5`. The described boundary remains present.

## Problem

Only max_attempts is validated. Nonpositive lease_s permits immediate concurrent reclaim; negative max_delay_s yields negative backoff; invalid or nonfinite intervals/jitter reach sleeps, Random or SQL.

## Remediation

Extend the existing configuration boundary with finite/range checks for lease, polling interval, retry delays and jitter. Preserve supported zero retry delays and negative unlimited attempt counts.

## Acceptance criteria

- Invalid timing values return Config before database access or signal registration; defaults, zero retry delay and unlimited attempt counts remain accepted. Add a focused runtime/config regression check.
- Update a runnable example/demo for application-facing behavior, or record why this is an internal-only refactor.
- Record the per-language capability verdict for framework/application contracts, or explain why language parity is unaffected.
