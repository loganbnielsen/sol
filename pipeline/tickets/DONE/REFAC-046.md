---
id: REFAC-046
type: refactor
severity: high
source: codebase simplification review 2026-06-16
branch: REFAC-046/split-cmd-pipeline
worktree: ../sun-REFAC-046-split-cmd-pipeline
---

Split monolithic `cmd_pipeline.ml` (663 lines) into focused library modules

**Depends on:** None.

**Description:**

`tools/sundev/bin/cmd_pipeline.ml` is a 663-line single-file module that conflates five distinct concerns in a `bin/` file:

1. **Ticket frontmatter parsing** (lines 131–318) — `parse_frontmatter`, `fm_get`, `parse_depends`, `has_human_decision_gate`, `find_ticket`, `dependency_status` — 190 lines of pure logic buried in a binary, unreachable from tests.
2. **Merge conflict resolution** (lines 56–128).
3. **`pipeline merge` command** (lines 321–461).
4. **`pipeline review` command** (lines 464–524).
5. **`pipeline ls`/`check` commands** (lines 527–600).

Additionally, `starts_with` (line 169) and `contains_substring` (line 173) are private local functions that duplicate helpers already present in `sun_cli_shell.ml:18–27` and `cmd_pipeline.ml` itself.

Because all logic is in `bin/`, none of the ticket parsing or merge logic can be unit-tested independently.

**Remediation:**

1. Extract the ticket model (frontmatter parsing, dependency resolution, decision-gate detection) into `tools/sundev/lib/sundev_ticket.ml` + `sundev_ticket.mli`. Add unit tests in `tools/sundev/test/test_ticket.ml`.
2. Extract the merge-conflict resolution logic into `tools/sundev/lib/sundev_merge.ml`.
3. Reduce `cmd_pipeline.ml` to a thin Cmdliner dispatcher (<100 lines) that calls into the library modules.
4. Remove the local `starts_with`/`contains_substring` definitions and import them from `Sun_process` or `Sun_cli_shell`.

**Acceptance criteria:**

- `wc -l tools/sundev/bin/cmd_pipeline.ml` reports fewer than 120 lines.
- `tools/sundev/lib/sundev_ticket.ml` exists and has unit tests.
- `dune build tools/sundev/` and `dune test tools/sundev/` pass.

## Review — automated checks passed
All acceptance criteria met: cmd_pipeline.ml is 63 lines, sundev_ticket.ml and test_ticket.ml exist, dune build and dune test pass, project/tickets/ is untouched, starts_with/contains_substring removed from cmd_pipeline.ml, no wrapped true in dune files.
