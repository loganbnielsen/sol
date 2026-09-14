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
