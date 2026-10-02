---
id: VERIF-003
type: refactor
severity: high
title: The canonical test runner fails a green tree, and correctness is coupled to performance
source: internal/pipeline/audits/2026-10-01_verification_architecture_audit.md
---

The canonical test runner fails a green tree, and correctness is coupled to performance

**Depends on:** None.

**Premise re-verified (2026-10-01)** against `origin/main @ fd138b3a`:
`bash internal/tooling/scripts/run_tests.sh unit` on an unmodified tree printed
`unit  pass  7.859s  2.310s  1.5×` and then `✗ Performance regression detected (exceeded per-suite
threshold).`, exiting **2** with every test passing. `run_tests.sh` holds its own timeouts and
failure ratios (`TIMEOUTS` at line 16, `FAIL_RATIOS` at line 22), its own suite set (`ALL_SUITES`,
line 43), and appends to the main-only `perf_baseline.json`; `internal/tooling/scripts/perf.sh`
holds a second, different set (`unit kafka observability storage e2e`) of the same ratios and only
reads that file.

## Problem

Three distinct concerns were implemented as one exit status:

1. `run_tests.sh` is the documented canonical runner (`/e2e` skill, AGENTS.md § Tests), so a nonzero
   exit means "the suite failed". It currently returns 2 for a fully green tree, and
   `soldev pipeline merge-finish` runs it after every merge and reports the result — so post-merge
   reporting is permanently red and readers learn to ignore it.
2. The regression comparison is between different machines. The committed baseline for `unit` is
   2.310 s against 7.859 s here for the same suite; `install-hooks.sh` registers
   `merge.ours.driver true` for the baseline file, so every local append is discarded when `main`
   moves. Nothing in the record identifies the host class.
3. A whole-suite timeout (`TIMEOUTS[unit]=60`, applied with `timeout -s KILL`) is doing duty as a
   performance expectation: a suite that legitimately grows past it reports `timeout`, which reads
   as a correctness failure.

## Desired invariant

Correctness and performance are different concerns with different owners. A correctness run exits 0
or nonzero and nothing else. Performance is a report over durations compared within one host class,
informational, never an exit code, and never written into `main` from a development machine. A
timeout exists to detect a hang, is generous, and is named as a hang bound.

## Remediation

Give `run_tests.sh` a correctness-only exit contract. Move every ratio, threshold and baseline
comparison into `perf.sh`, key baselines by host class (or record the host with each entry and
compare only like with like), and make the post-commit hook print a report with no failure
semantics. Keep one definition of each suite's membership: after VERIF-004 this script should be a
thin wrapper over the class targets plus provisioning.

## Acceptance criteria

- `bash internal/tooling/scripts/run_tests.sh` exits 0 on a green tree and nonzero only when
  something failed; a suite that is merely slower still passes.
- No performance ratio or threshold appears in `run_tests.sh`; `perf.sh` is the only owner, and a
  comparison across unlike hosts is either impossible or explicitly labelled.
- The hang bound is documented as a hang bound, is comfortably above observed runtimes, and its
  breach is reported as a hang with the suite named.
- `git log` on `internal/tooling/perf/perf_baseline.json` shows no entry written by a developer
  machine without `--update-baseline`, and the baseline's `note` no longer names a path that does
  not exist.
- Demo/example: not applicable — repository tooling only. Language parity: no application-facing
  contract changes; state that in one line.

## Completion notes (2026-10-02)

**Premise re-verified** against `origin/main @ 310917dd`: `run_tests.sh` held `FAIL_RATIOS` and
returned `2` on a green-but-slower tree; the audit recorded `run_tests.sh unit` printing
`unit pass 7.859s 2.310s 1.5×` and exiting 2 with every test passing. `perf.sh` held a second,
different ratio table and only read the baseline.

**Implemented.**

- `run_tests.sh` is correctness-only: no `FAIL_RATIOS`, no `baseline_get`/`baseline_append`, no
  regression exit. It exits 0 when every suite passed and 1 otherwise. `TIMEOUTS` became
  `HANG_BOUNDS` (unit 300s, kafka 900s, e2e 1200s), printed at startup and in the summary; a suite
  killed at its bound is reported as `hang`, naming the suite and the bound.
- `perf.sh` owns every ratio, threshold and comparison. It adds `record`: run a suite (through
  `run_tests.sh`, so membership stays single-sourced) and report its duration against the same-host
  baseline. `record --update-baseline` is the only writer — it appends an entry carrying `host`
  (`uname -srm`) and marks it the baseline; without the flag nothing is written (verified with
  `cmp`). `status` compares only when baseline and latest carry the same host; otherwise drift is
  `n/a` and the two hosts are named under the table. `perf.sh` always exits 0 — a report, not a gate.
- `soldev merge-finish` no longer has a perf verdict: `Report_perf_regression` is removed and
  `post_merge_action_of_rc` is `0 → success`, anything else → local failure.
- `perf_baseline.json`'s `note` names `perf.sh record --update-baseline` (the old
  `./cli/platform/local/scripts/run_tests.sh` path did not exist). AGENTS.md and the `/e2e` skill
  were corrected; `run_tests.sh` no longer accepts `--update-baseline`.

**Evidence** (worktree, pinned kubectl v1.29.0 on PATH):

```
run_tests.sh unit                                  -> unit passed (7.736s), exit 0
```

Before this change the same ~7.7s run against the 2.310s baseline (1.5× ⇒ 3.465s) exited 2.

```
perf.sh record unit                     -> 9.322s … no same-host baseline; writes nothing (cmp: identical)
perf.sh record unit --update-baseline   -> 9.335s recorded as the new baseline on Linux-6.6.87.2-…-x86_64
perf.sh record unit                     -> 6.873s vs baseline 6.883s on Linux-… (-0%)
planted 6× entry in status              -> +500% shown in red; perf.sh status exits 0
```

**Checks:** `bash internal/ci/run_fast_checks.sh` → `0/66 failed`; `check_ocamlformat.sh --all`
clean; `dune test internal/tooling/soldev/test/` → 53 + 27 pass (the `post_merge_action_of_rc`
case now expects exit 2 to be a plain failure).

**Demo/example:** not applicable — repository tooling only. **Language parity (DEC-022):** no
application-facing contract change; the runner is language-neutral.

**Left for VERIF-004:** suite membership is still written in `run_tests.sh` and `perf.sh`
(`RECORDABLE_SUITES`); unifying it onto the class aliases is VERIF-004's scope.
