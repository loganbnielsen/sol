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
