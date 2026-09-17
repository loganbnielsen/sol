---
id: INFRA-020
type: feature
severity: medium
title: Remove CI evidence reuse; keep one fail-closed support-package snapshot per run
source: review of INFRA-019 (#289), 2026-09-17
---

**Depends on:** None.

INFRA-019 added historical CI evidence reuse to avoid rerunning byte-identical
code after an update from `main`. On review, the mechanism was judged too
complex for its value and too close to the merge-safety boundary. A new
pull-request head simply reruns its CI. This ticket removes the reuse and keeps
the part that fixes a real reproducibility gap.

## Scope

- **Remove:**
  - `devtools/ci/ci-evidence.sh` and its tests;
  - the evidence lookup, record and upload steps in `classify`;
  - the `run_suite`/`reused_run` outputs and the reuse summary.
  - `classify` returns to its pre-INFRA-019 form, and jobs gate on
    `kind != 'docs-only'` again.
- **Keep:** `packages.txt` as the single ordered support-package list.
- **Resolve once, fail closed:** a new `support-refs` job resolves every support
  package's `main` commit once per workflow run
  (`devtools/ci/resolve-support-packages.sh`), and every building job pins
  exactly that snapshot. The pin action requires a commit for every package; it
  never falls back to `#main` on its own. An incomplete snapshot fails the
  building jobs with a pointer to the resolver log.
- **Other callers:** the manually triggered `fn-svc-isolation-spike` workflow
  resolves its own snapshot the same way.

Replacing `#main` with released support-package versions stays with RELEASE-005.
Capability-aware job selection is filed separately in BACKLOG.

## Acceptance criteria

- No historical-run lookup or evidence artifact remains in CI.
- A full run's building jobs all pin the same support-package commits, and the
  resolved list appears in the `support-refs` log.
- An unresolvable support package fails the run instead of floating on `#main`.
- `devtools/ci/test_resolve_support_packages.sh` covers two cases: a complete
  snapshot resolves, and one unresolvable package fails.

**Demo/example coverage:** Not applicable; CI internals.

**TypeScript parity:** No language impact.

## Completion notes (2026-09-17)

- **Removed:** `ci-evidence.sh`, `test_ci_evidence.sh`, and the evidence steps,
  outputs and summary. Diffed against the pre-INFRA-019 workflow, `ci.yml` now
  differs only by the `support-refs` job, the `needs`/`refs` wiring on the
  three building jobs, the resolver test step, and `packages.txt` in the opam
  download-cache key.
- **Resolver:** `resolve-support-packages.sh` (about 20 lines) has two tests.
  Run against the real list, it resolved all 11 packages.
- **Pin action, checked locally** by running its loop with `opam` stubbed out:
  - a complete snapshot pins every package at its resolved commit;
  - removing one package fails with the "no resolved commit" error.
- **Docs-only changes:** `support-refs` is gated on classification like the
  other expensive jobs, so a docs-only change resolves nothing, and the
  required `test` check stays a lightweight success. A failed classification
  still resolves and runs everything.
- **Other callers:** `fn-svc-isolation-spike.yml` now resolves its own snapshot.
  `release.yml` keeps its separate `#main` pins, which stay with RELEASE-005.
