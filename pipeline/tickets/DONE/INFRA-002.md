---
id: INFRA-002
type: bug
severity: medium
source: pipeline observation 2026-06-15
branch: INFRA-002/per-suite-perf-thresholds
worktree: /home/lbendtly/Code/sun-INFRA-002-per-suite-perf-thresholds
---

Tighten perf gate: suite-specific thresholds and infra-isolated unit timing

**Depends on:** None.

**Description:** The pipeline's performance regression gate uses a single 1.2× threshold for all suites and measures the unit suite while Redpanda, Loki, and PostgreSQL are simultaneously running. When the full five-suite pipeline fires on a single host, I/O and scheduler contention from live infrastructure routinely pushes the unit suite from ~1.3s to ~2.2s — a 1.5–1.75× apparent regression — even for changes with zero hot-path impact (vendor directory skip, structured YAML emitter, metric label filter). This has forced three legitimate merges through a `--accept-performance-regression` bypass and triggered repeated false-positive blocking cycles.

**Impact:** The perf gate is producing more noise than signal. Every merge that touches any file now risks a spurious block, which erodes trust in the gate and trains the pipeline operator to override it reflexively.

**Remediation:**

1. Run the `unit` suite **before** `ensure_infra` starts any containers, so its timing is not contaminated by background infrastructure load. Reorder `run_tests.sh` to: run unit → start infra → run kafka/observability/storage/e2e.
2. Introduce **per-suite thresholds** in `run_tests.sh` (or `perf_baseline.json`). Proposed values based on observed variance:
   - `unit`: 1.5× (pure OCaml, no I/O — variance comes only from GC and scheduler)
   - `kafka`, `observability`, `storage`: 1.4× (I/O-bound; more variance is expected)
   - `e2e`: 1.5× (sequential multi-step; timing swings are larger)
3. Update `perf.sh status` / `history` to display per-suite thresholds instead of the single global `FAIL_RATIO`.

**Acceptance criteria:**

- Unit suite timing is measured before any infra containers are started.
- Each suite has its own regression threshold in the runner.
- A clean run of `run_tests.sh` on an idle machine shows no spurious regressions for changes that don't touch test or hot-path code.
- `perf.sh status` reflects the per-suite thresholds.

## Review — automated checks passed
All ticket requirements satisfied: unit runs pre-infra, FAIL_RATIOS array present with correct values in both scripts, is_regression takes suite arg, status shows Thresh column, history annotations include threshold, project/tickets/ untouched, build clean
