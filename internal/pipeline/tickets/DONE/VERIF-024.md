---
id: VERIF-024
type: verification
severity: medium
title: A guard's opt-out is reachable from the canonical verification path
source: internal/pipeline/tickets/DONE/VERIF-006.md (PR #939 review, 2026-10-02)
---

A guard's opt-out is reachable from the canonical verification path

**Depends on:** VERIF-006.

**Premise re-verified (2026-10-02)** against `origin/main @ f7d45074`:
`internal/ci/check_gcloud_interface.sh:77` still reads
`CHECK_GCLOUD_INTERFACE_ALLOW_MISSING_GCLOUD`, and `internal/tooling/scripts/verify.sh`
passed the ambient environment to every class member, so the canonical path could
still select the weaker branch.

`check_gcloud_interface.sh` fails when `gcloud` is absent, naming one opt-out,
`CHECK_GCLOUD_INTERFACE_ALLOW_MISSING_GCLOUD=1`, so a machine that lacks the CLI can still run its
static half. Nothing stops the authoritative path — the required `test` job, which reports that the
argv matched the real CLI — from setting that variable, or from inheriting it from the environment
it is launched in. The escape hatch is trusted by convention.

## Problem

A guard that prints "the gcloud interface was not validated (explicit opt-out)" while the required
gate is green lets the tier that is supposed to verify Sol's argv stop doing so without the gate
changing colour. It is the class VERIF-006 removes, one level up: the guard no longer passes
vacuously, but the authoritative environment can still choose its weak branch. The opt-out is
legitimate for a developer machine or a deliberately weaker local run; it is not legitimate for the
gate that claims the check ran.

## Desired invariant

The canonical verification path cannot select a guard's opt-out. Either the environment the gate
runs in cannot carry the variable, or the gate asserts its absence and fails naming it. The weaker
branch stays reachable only from an explicitly weaker context, and says what it did not validate.

## Remediation

Choose the structural form that fits the VERIF-005 class runner: for example, the class runs under
an environment that clears or asserts the absence of every guard opt-out, or the guard refuses the
opt-out when the canonical context is declared (`CI=true`), making the weak branch unreachable
there. Pair it with a sweep so a new opt-out cannot be added without a verdict: a check that lists
every opt-out variable a guard reads and requires each to be either unreachable in the canonical
path or recorded as deliberately local-only. The sweep must fail on a new unclassified variable,
not merely print it.

## Acceptance criteria

- `CHECK_GCLOUD_INTERFACE_ALLOW_MISSING_GCLOUD=1` in the canonical `test` job cannot yield a green
  run that skipped the interface check; the gate ignores it or fails naming it.
- The weaker branch is still reachable from an explicitly local/weaker invocation and reports that
  the interface was not validated.
- A repository-wide check enumerates the opt-out variables the guard scripts read, so a new one is
  surfaced rather than trusted by convention.
- Demo/example: not applicable — CI tooling only. Language parity (DEC-022): no application-facing
  contract change.

## Completion (2026-10-02)

Implemented on `VERIF-024/guard-optout-unreachable`.

- `internal/ci/guard_env.txt` classifies every optional environment input a guard
  reads: `CHECK_GCLOUD_INTERFACE_ALLOW_MISSING_GCLOUD clear` and the
  `SOL_AUTHORITY_*` declarations `read`.
- `internal/tooling/scripts/verify.sh` gains `unset_canonical_inputs`, called by
  every member invocation: a `clear` entry is removed from the environment before
  the member runs, so the class runner ignores the opt-out. A new guard input
  defaults to failing the sweep, not to being trusted.
- `internal/ci/always/check_guard_env.py` is the sweep. It scans every `check_*`
  guard for shell `${VAR:-…}` reads and Python `os.environ`/`getenv` reads that
  are not stock environment and not computed in-file, requires each to be
  classified, and fails on an unclassified or stale entry. It names the variable
  and the guard that reads it.
- `internal/ci/test_gcloud_interface.sh` now pins the canonical path: with the
  opt-out exported, running the guard after `unset_canonical_inputs` fails, while
  the direct weaker invocation still passes and says the interface was not
  validated. `internal/ci/always/test_guard_env_check.py` is the sweep's mutation
  suite (unclassified, stale, unknown verdict, malformed line, computed local,
  duplicate).
- Checks: `check_guard_env.py`, `test_guard_env_check.py`,
  `test_gcloud_interface.sh`, `internal/ci/verify_test.sh` (including the new
  clear-classified fixture case), `verify.sh always` 9/9, `verify.sh static`
  0/97, and `check_no_comments.sh` (825 files). No OCaml changed.
- Demo/example: not applicable — CI tooling only. Language parity (DEC-022): no
  application-facing contract change.
