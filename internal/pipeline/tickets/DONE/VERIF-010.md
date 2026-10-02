---
id: VERIF-010
type: refactor
severity: medium
title: External-tool and Dockerfile inventories are duplicated, one of them self-declared unguarded
source: internal/pipeline/audits/2026-10-01_verification_architecture_audit.md
---

External-tool and Dockerfile inventories are duplicated, one of them self-declared unguarded

**Depends on:** None.

**Premise re-verified (2026-10-01)** against `origin/main @ fd138b3a`: the k3d v5.6.0 / helm v3.21.0 /
kubectl v1.29.0 downloads are written twice (`.github/workflows/ci.yml:878-895` and
`ci.yml:1481-1493`), and `ci.yml:794-798` states that they must stay in sync with
`internal/pipeline/dogfood/DOGFOOD.md`'s toolchain table by hand, with no drift check.
`git ls-files '*Dockerfile*'` under `examples/` and `internal/fixtures/` returns seven files; the
`example-dockerfile-smoke` matrix (`ci.yml:1289-1299`) covers five and `demo-ts-dockerfile-smoke`
(`ci.yml:1338-1339`) two. AGENTS.md makes adding an entry to that matrix an author's manual
obligation.

## Problem

Two hand-maintained lists describe the same sets, so a new example Dockerfile is silently never
built, a version bump is a three-place edit, and the repository's own documentation admits nothing
checks the agreement. This is the case where the correct answer is not another checker: both lists
can be derived, and the derivation can be made the only source.

## Desired invariant

One definition of the CI toolchain, read by every job that needs it, and a Dockerfile set derived
from the tree rather than enumerated. A failed derivation (no matches, or a path matched twice) is
an error, not an empty matrix — an empty matrix is a suite that runs nothing.

## Remediation

Put the pinned toolchain in one place that the jobs read (a sourced shell definition or a pinned
toolchain action), and derive the Dockerfile matrices from `git ls-files` with an explicit,
one-line exclusion for anything intentionally out of scope (today: the hand-maintained TypeScript
demo Dockerfiles, which have their own job). Keep the version-to-`DOGFOOD.md` relationship either by
having that document read the definition or by a guard on the single remaining pair; do not add a
second synchronisation check for two derived lists.

## Acceptance criteria

- Each external tool's version appears once in the repository's executable configuration.
- Adding a Dockerfile under `examples/` or `internal/fixtures/` makes it build in CI, or fails with
  an explicit message saying it is excluded and why.
- A matrix or inventory that derives nothing fails, naming what it derived from.
- Demo/example: this *is* the example-coverage machinery; state in one line which set is derived and
  which is deliberately excluded.
- Language parity (DEC-022): the TypeScript demo's Dockerfiles keep their job; confirm the
  derivation covers them or record them as the named exclusion.

## Completion notes (2026-10-02)

**Premise verified** against `origin/main @ 5efaeef2`: the k3d v5.6.0 / helm v3.21.0 / kubectl
v1.29.0 downloads appeared three times (the `test` job's kubectl-only step and two
`golden-path-smoke*` steps), and `ci.yml:794-806` said in a comment that nothing checked the
sync with DOGFOOD.md's table. The two Dockerfile matrices were hand-written
(`example-dockerfile-smoke` 5 entries, `demo-ts-dockerfile-smoke` 2).

**Implemented.**

- **One toolchain definition.** `internal/tooling/scripts/ci-toolchain.sh` holds
  `K3D_VERSION`/`HELM_VERSION`/`KUBECTL_VERSION` and installs pinned release binaries (never
  `curl | bash`). All three `ci.yml` install steps call it — `ci-toolchain.sh kubectl` for the
  readiness-probe job, `ci-toolchain.sh` for the two smoke jobs. `SOL_TOOLCHAIN_DEST` lets the
  doc's user-local install reuse the same pins.
- **Derived Dockerfile matrices.** `internal/tooling/scripts/dockerfile_matrix.py` derives both
  matrices from `git ls-files`: `examples` (every Dockerfile under `examples/` and
  `internal/fixtures/`, minus the TypeScript demo, with its build context) and `demo-ts` (the
  services under `examples/pluto/app/demo_ts/`). A new `dockerfile-matrix` job emits both as step
  outputs; `example-dockerfile-smoke` and `demo-ts-dockerfile-smoke` consume them with
  `fromJson`. A derivation that names nothing exits nonzero with the paths it searched.
- DOGFOOD.md's "Kubernetes toolchain" section now points at the script for the versions (its
  table and hand-pinned install commands are gone); AGENTS.md's "New example Dockerfiles go in
  the CI matrix" instruction is replaced by "they are derived automatically".
- `check_unconditional_guard_tooling.py`'s `resolve()` now also follows scripts under
  `internal/tooling/scripts/`, so it can still see the `test` job's kubectl provider through the
  shared script. This is an interim accommodation: VERIF-005 deletes that guard.

**Evidence** (worktree):

```
python3 internal/tooling/scripts/dockerfile_matrix.py examples
  -> {"include":[ 5 entries ...]}
python3 internal/tooling/scripts/dockerfile_matrix.py demo-ts
  -> {"service":["fulfillment_worker","order_svc"]}
# planted examples/pluto/app/newsvc/Dockerfile (git add -N) -> appears in the derived include
# empty git tree -> exit 1: "git ls-files underneath examples/ and internal/fixtures/ named no Dockerfile"
rg -n 'v5\.6\.0|v3\.21\.0|v1\.29\.0' (excluding tickets/audits/run records)
  -> only internal/tooling/scripts/ci-toolchain.sh
```

**Checks:** `run_fast_checks.sh` → 0/66; `check_unconditional_guard_tooling.py` and its mutation
suite pass; `test_docs_only_path.py` 4/4; `check_workflow_paths.py` clean; `check_no_comments.sh`
clean; `ci.yml` parses.

**Demo/example:** this *is* the example-coverage machinery. Both sets are derived from
`git ls-files` — the OCaml examples and `internal/fixtures/venus` into
`example-dockerfile-smoke`, the TypeScript demo into `demo-ts-dockerfile-smoke`; neither is a
hand-written list, so nothing is "deliberately excluded" any more. **Language parity (DEC-022):**
the TypeScript demo keeps its own job, now fed by the derived `demo-ts` matrix.

**Left for VERIF-005:** the ~70 guard steps still enumerate in `ci.yml`; deleting
`check_unconditional_guard_tooling.py`, `test_docs_only_path.py` and
`test_unconditional_guard_tooling.sh` is that ticket's scope.
