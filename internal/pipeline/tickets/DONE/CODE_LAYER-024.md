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

## Completion (2026-09-29)

- **Premise re-verified** at origin/main `788e688d`: `open_prs` used `Sol_process.output_shell` (`2>/dev/null`, no exit status) and mapped an empty string to `[]`, so an authentication/network failure was indistinguishable from no open PRs — `merge` printed "No open PRs to merge." and `ls` silently dropped every annotation. `run_ls` also called `find_pr_for_ticket` per READY ticket, each a fresh `gh pr list`.
- **Fix.** `open_prs` is now a typed `(pr_info list, Soldev_exit.failure) result` over a checked `Sol_process.run_argv ["gh"; "pr"; "list"; …]`: a nonzero exit yields the plugin's own diagnostic, an unparseable payload or wrong shape is an error, and a successful `[]` is an empty inventory. `find_pr_in` does the local lookup against a resolved list, and each operation resolves the inventory exactly once — `run_ls` (once for the whole listing), `run_merge` (once for both the single-ticket filter and the sweep), `run_submit`, `run_review`, `run_check`. `find_pr_for_ticket` is gone (no remaining caller).
- **Tests** (`internal/tooling/soldev/test/test_pr_inventory.py`, wired as a `runtest` rule beside `test_cleanup.py`): a temporary repo with two READY tickets and a fake `gh` that counts invocations and can fail with `audit-authentication-failed`. Asserts: a failing `gh` makes both `pipeline ls` and `pipeline merge` exit nonzero carrying that diagnostic (`merge` no longer prints "No open PRs to merge."); a successful `[]` is an empty inventory with exactly **one** `gh pr list` call; a PR list annotates only the matching ticket (`PR #77`) from that same single inventory. **Mutation-checked**: making the failed retrieval return `[]` fails the first assertion while the fix passes. All soldev tests (`dune build @internal/tooling/soldev/test/runtest`) pass.
- Validation: `dune fmt --preview` and `check_no_comments.sh` clean; `pipeline validate` reads all tickets.
- **Demo/example: not applicable** — maintainer tooling (`soldev`), no app-author surface. **Language parity: no impact** — no framework or application contract changes.

- **CI follow-up (2026-09-29):** `internal/ci/test_pipeline_validate.sh` now creates a stub `gh` that answers `[]` and prepends it to `PATH`, because `pipeline ls`/`check` legitimately require a readable PR inventory and the CI `test` job has no `GH_TOKEN`; the script's own assertions (unreadable ticket named, listing green again) then hold unchanged.
