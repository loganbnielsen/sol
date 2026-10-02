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

## Completion notes (2026-10-02)

**Premise re-verified** against `origin/main @ 6a9d7cba` (after VERIF-004/007): the required `test`
job had 104 steps, roughly 85 of them one guard or mutation self-test per step, each repeating the
classify condition. `internal/ci/` held 51 `check_*` and 55 `test_*` files plus the three
meta-guards.

**Implemented.**

- **One entry point.** `internal/tooling/scripts/verify.sh <class>` discovers a class by directory
  and runs each `check_*`/`test_*` member in parallel, with a `PASS`/`FAIL` line and timing each.
  It refuses an unknown class, a class directory that is missing, and an empty class; it requires a
  result per member and treats a missing or unreadable result as a failure that names the member;
  and it sanitizes Git's exported environment (VERIF-008) before running anything.
- **Classes.** `internal/ci/` is `static` (product/source/config invariants and their mutation
  self-tests); `internal/ci/always/` is `always`, the cheap offline invariants that must hold on
  every path including docs-only; `internal/ci/context/` holds the few members whose invocation is
  supplied by the caller (a piped ticket diff, a branch name, a Dune rule's stdout), invoked
  explicitly. Membership is the filename marker inside the class directory, so adding a guard is one
  file in its class and no edit to `ci.yml`.
- **The workflow names classes.** The `test` job dropped from 104 to 28 steps: `always` runs
  unconditionally, `static` carries the single classification condition, and a step runs
  `internal/ci/verify_test.sh` to pin the runner's own fail-closed cases. The docs-only path still
  runs the cached `pipeline validate`, the ticket-transition and ticket-move guards, and `always`;
  `classify-changes.sh` still falls back to `source` for an unrecognised classification.
- **`run_fast_checks.sh` is a thin orchestrator.** It builds, runs `@ci-unit`/`@ci-lifecycle`, runs
  the two context-bound checks, then delegates the guard suite to `verify.sh always|static`. Its
  66-entry inventory and its result-reporting loop (VERIF-009's defect) are gone.
- **The meta-guards are deleted.** `check_unconditional_guard_tooling.py`, `test_docs_only_path.py`
  and `test_unconditional_guard_tooling.sh` are removed with their steps. `check_workflow_paths.py`
  is kept (executability and `paths:` filters are GitHub-Actions semantics) as a `static` member.

**Acceptance.**

- `ci.yml` names classes: 104 steps → 28, with `verify.sh always` and `verify.sh static`.
- Adding a guard is one file in its class; `verify_test.sh` proves an unknown class, an empty class,
  a missing class directory, a failed member and a member with no result each stop the run.
- The docs-only path still validates tickets and transitions, and the product suite still cannot be
  skipped for a non-docs change (the classifier's fail-closed fallback is intact).
- **Coverage increased.** The class glob now also runs guards that were wired nowhere or only into a
  mutation copy: `check_authority.sh`, `check_cluster_access_identity.py`,
  `check_gcp_provisioner_role.py`, `check_public_cloud_lifecycle.sh`,
  `check_publisher_deployer_boundary.sh`, `check_ts_demo.sh` and `test_resource_identity_check.py`.

**Evidence.**

```
$ bash internal/ci/run_fast_checks.sh                 # EXIT=0, 139s warm
  verify always: 0/7 members failed
  verify static: 0/96 members failed
  verify runner: every expectation held.
$ python3 internal/ci/check_workflow_paths.py         # 3 paths entries, 3 scripts, all executable
$ bash internal/ci/check_no_comments.sh               # 817 files checked, none has a comment
$ python3 internal/ci/test_resource_identity_check.py # runs; its output names the guard
$ python3 internal/ci/check_cluster_access_identity.py   # real-tree verdict
$ python3 internal/ci/check_gcp_provisioner_role.py      # real-tree verdict
```

The meta-guards are deleted in this same PR because the replacement is already proven: the class
runner's own test demonstrates each fail-closed property they used to defend by inspecting `ci.yml`.

**This makes VERIF-009 and VERIF-011 structural.** The runner requires a result per member and names
any member with none (VERIF-009's acceptance, tested in `verify_test.sh`), and every
`internal/ci/check_*`/`test_*` file is a class member by construction, so an unwired guard or
mutation test cannot recur (VERIF-011's acceptance). Both are closed in a follow-up that records it.

**Demo/example:** not applicable — CI tooling only. **Language parity (DEC-022):** no
application-facing contract changes.
