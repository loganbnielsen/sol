---
id: VERIF-005
type: refactor
severity: high
title: The workflow enumerates ~70 guards, so 2346 lines exist to check the enumeration
source: internal/pipeline/audits/2026-10-01_verification_architecture_audit.md
premise: '! rg -q check_unconditional_guard_tooling .github/workflows/ci.yml'
---

The workflow enumerates ~70 guards, so 2346 lines exist to check the enumeration

**Depends on:** VERIF-004.

**Premise verified (2026-10-01)** against `origin/main @ fd138b3a`: `.github/workflows/ci.yml` is
1,713 lines with 130 named steps in the required `test` job, of which roughly 70 invoke a guard or a
guard's mutation self-test by name, each repeating the
`needs.classify.outputs.kind != 'docs-only' || steps.docs_tooling.outputs.cache-hit != 'true'`
condition. `internal/ci/` is 13,049 lines over 106 files: 51 `check_*` guards (5,028 lines) and 55
`test_*` mutation/self-test scripts (7,315 lines). About 2,346 lines across 20 files have the CI
wiring, the ticket machinery, the hook install or suite coverage as their subject.

## Problem

`internal/ci/check_unconditional_guard_tooling.py` re-implements a dependency graph over shell
scripts (a script-name regex, a `reaches` walk, an artifact regex, and an `INSTALLS` regex) to
answer "does every step's tooling get provided by an earlier unconditional step, on both the full
and the cached docs-only path", and `test_docs_only_path.py` asserts properties of that model. A
second `ci.yml`-shaped guard, `check_workflow_paths.py`, covers a different part of the same file.
This is machinery whose subject is the arrangement of a 1,713-line YAML file: it is not
establishing a product invariant.

Two weaknesses inside it, both read from the code and marked as such because neither was triggered:
its `PROVIDED_BY_A_STEP` allow-list names only `kubectl`, `shfmt` and `ocamlformat`, so a step that
requires an unrecognised binary passes the guard and fails at runtime; and it cannot distinguish
"this guard could not observe its input" from "this guard observed a clean tree". The optimisation
it protects is itself well built and fail-closed (empty `kind` runs everything; the cached validator
has no fallback keys and is saved only by trusted `main` pushes), so the exposure is maintenance
cost and a partial model's false confidence, not an observed false success.

## Desired invariant

Adding a static invariant is one file plus a declaration next to it. The workflow states which
*classes* run, not which scripts. Nothing in the repository exists only to keep two lists of the
same scripts in agreement.

## Remediation

Classify guards by directory (the same convention `internal/pipeline/tickets/` uses to encode
status: the directory is the marker) and give each class one repository tooling entry point that
globs its members and refuses an empty class. `ci.yml` then invokes a handful of class commands
instead of stepping through ~70 guards, and the docs-only branch skips exactly the expensive class
rather than carrying a repeated condition on 25 steps. Preserve the fail-closed properties
explicitly: unknown classification runs everything, a class with no members is an error, a missing
guard file is an error, and ticket validation runs on every path. Delete
`check_unconditional_guard_tooling.py`, `test_docs_only_path.py` and
`test_unconditional_guard_tooling.sh` only after the replacements demonstrably keep those
properties, and keep `check_workflow_paths.py` (executability and the `paths:` filters are genuine
GitHub-Actions semantics).

## Acceptance criteria

- `ci.yml` names verification classes, not individual guards, and the number of steps in the
  required job drops accordingly.
- Adding a guard requires no edit to `ci.yml`; adding a class requires one line.
- An empty class, a missing member and an unrecognised classification each fail closed, each
  demonstrated by a case in the class runner's own test.
- The docs-only path still runs ticket validation and transitions, and still cannot silently skip
  the product suite for a non-docs change.
- The three meta-guards are deleted, in the same PR only if the replacement is already proven; the
  deletion is otherwise its own commit with the evidence in the completion notes.
- Demo/example: not applicable — CI tooling only. Language parity: no application-facing contract
  changes; state that in one line.
