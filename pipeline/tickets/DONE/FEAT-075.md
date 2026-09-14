---
id: FEAT-075
type: feature
severity: low
source: FEAT-066 review, 2026-09-14 — untested orchestration order
---

Pin `sol rollback`'s enforcement order with a test

**Description:** FEAT-066's load-bearing ordering — resolve → load/validate → apply-mode refusal → migration boundary check → reconstruct → render → apply → verify live workload set → move pointer → verify pointer — lives entirely in `cmd_rollback.run`, a `bin` module with no test. The reconstruction gate (A/B/C) covers reconstruction; the pure report tests cover verification. Nothing would catch a regression that moved the pointer above the apply loop, or moved the migration/ownership refusal after a mutation. "A refused rollback leaves the cluster untouched" is guaranteed only by statement order in an untested function.

**Impact:** A future refactor of `cmd_rollback.ml` could reorder a mutation ahead of a refusal check, or move the pointer before workload verification, and the suite would stay green.

**Remediation:** Extract the sequence into the library as an injectable transaction (`~apply`, `~move_pointer`, `~verify_workloads`, `~verify_pointer` as functions or a record of them), then test that (a) no mutation runs when the apply-mode refusal or migration check returns an error, and (b) the pointer move is never called when workload verification fails. This mirrors how `live_kind_of_service`/`live_resource_and_jsonpath` were lifted out of the command for testability. If extraction proves awkward, a thinner test asserting the call order through stubs is still strictly better than nothing.

## Completion notes

- Did the real extraction, not the thinner fallback. `Sol_cli_rollback.execute
  ~release ~migrations_dir ~current_migrations ~deps` (`cli/sol/lib/`) now
  owns the full sequence: apply-mode refusal → migration boundary refusal →
  reconstruction → `deps.apply` → `deps.live_workloads` + `verify_workloads`
  → (only if that agrees) `deps.move_pointer` → `deps.verify_pointer`.
  Reconstruction and the two boundary checks stay direct calls (already
  pure/tested, no cluster state beyond what's passed in); only the four
  cluster-touching/mutating steps became a `transaction_deps` record, so a
  test can substitute stubs without a cluster.
- `cmd_rollback.ml`'s `run_locked` shrank to: resolve the release, print the
  banner, build `deps` from the real `ctx`/`release` (an `apply_specs`
  helper carries the render+apply loop and its own printing, since the
  library stays print-free like the rest of `sol_cli_rollback.ml`), call
  `execute`, print the final "Verified" line on `Ok`. All ordering logic is
  gone from `bin/`.
- Four new tests (`rollback_transaction` group, `test_rollback.ml`): success
  calls `apply`/`live_workloads`/`move_pointer`/`verify_pointer` in that
  exact order; a `Gitops` release's apply-mode refusal calls no dep at all;
  a contracting migration's boundary refusal calls no dep at all; an
  unexpected live workload (workload-set mismatch) calls `apply` and
  `live_workloads` but never `move_pointer`/`verify_pointer`. Each asserts
  the call list directly, not just the return value, so a reorder fails
  these tests specifically rather than only some downstream symptom.
- Left the seam for FEAT-074 (workload pruning): both `execute`'s doc
  comment and `transaction_deps`'s note the gap between workload-set
  verification and `deps.move_pointer` as where a `~prune` dep belongs, so
  that ticket has a dep to add to, not a new mechanism to invent.
- Updated `docs/architecture/devops-pipeline.md`'s `sol rollback` section to
  note steps 2–8's ordering is now this tested library function, not inline
  `cmd_rollback.ml` logic.
- No demo/example update: this is an internal testability refactor of
  `sol rollback`'s own command, not a new primitive, CLI surface, or
  generated manifest.
