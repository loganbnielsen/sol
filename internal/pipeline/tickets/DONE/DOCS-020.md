---
id: DOCS-020
type: docs-finding
severity: low
title: The other four framework specs have the same signature drift DOCS-017 fixed in two
source: DOCS-017 — found by running its new drift guard's rules over the remaining packages
---

**Depends on:** none.
**Related:** `DOCS-017` (the fix and the guard), `2026-09-16_docs_audit.md`.

## The gap

DOCS-017 corrected the specs for `kafka-eio-service` and `sol-svc` (14 stale
declarations) and added `internal/ci/check_framework_doc_signatures.sh` to keep them
honest. Its manifest covers those two files. The remaining four framework specs were
not in scope, and a pass with the same rules over them finds the same class of drift:

| Spec | Findings (before verifying each) |
|---|---|
| `framework/ocaml/sol-worker/sol-worker.md` | `run`'s `env`/`config` shape, and `retry_policy`/`retry_strategy` differing from the `.mli` |
| `framework/ocaml/sol-fn/sol-fn.md` | `run`'s `env` shape; `val push` and `val schedule` documented but not declared |
| `framework/ocaml/sol-obs/sol-obs.md` | `type level = Obs_eio.level = ...` — a re-export written as a declaration, which does not match |
| `framework/ocaml/sol-jobs/sol-jobs.md` | `run`'s signature; a user's `type job` example that reads as a framework declaration |

Two of those are the ad-hoc checker's own false-positive class rather than drift
(`sol-obs`'s re-export, `sol-jobs`'s example), so the first job is to sort real drift
from presentation before fixing anything — the same distinction DOCS-017 had to make
when it moved from comparing a doc against all of a package's mlis to mapping
sections to modules.

## Remediation

1. Extend the guard's manifest in `internal/ci/check_framework_doc_signatures.sh` to
   the four remaining specs, mapping each section to its module. Where a section is
   genuinely a *user* example (the message-contract and example sections), leave it
   out of the manifest rather than teaching the checker English.
2. Fix the declarations it then reports, copying the `.mli` text as DOCS-017 did.
3. If `sol-obs`'s `type level = Obs_eio.level = ...` is the intended way to document a
   re-export, say so in the guard rather than changing the doc to a form that is
   legal but less informative — a re-export has no single `.mli` declaration to match,
   and that is a real limit of a text comparison worth writing down.

## Acceptance criteria

- The guard's manifest covers all six framework specs, or the exclusions are named
  and justified in the guard itself.
- The remaining four specs' declarations match their `.mli`s.
- The mutation test still pins both directions (a stale declaration fails; a subset
  passes).

## Why this is `BACKLOG` and `low`

It is the same mechanical fix DOCS-017 just did, for documents nobody has reported a
problem with; the guard makes it a bounded, verifiable job whenever someone wants to
spend the cycle. It is filed rather than folded into DOCS-017 so that ticket's claim
stays exactly as wide as the evidence behind it.

## Disposition (2026-10-03) — actionable pre-alpha

Premise re-checked against current `origin/main`; the work is still real.
Evidence: `internal/ci/always/check_framework_doc_signatures.py` MANIFEST covers only `sol-svc` and `kafka-eio-service`; the four remaining specs are uncovered.

Promoted to `READY_FOR_ENGINEERING/` by the pre-alpha BACKLOG adjudication
(`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`).

## Completion (2026-10-03)

The guard now maps all seven framework specs, and every section of those specs that
carries an `ocaml` block is either mapped to the `.mli` it documents or named in a new
`EXCLUSIONS` list with the reason it is not a declaration surface. The coverage is
load-bearing rather than a comment: a section that is neither mapped nor excluded fails
the guard, and so does an exclusion that names a section the spec no longer carries.

### Premise checked, and corrected (base `ea9e11d9`)

The MANIFEST held only `sol-svc` and `kafka-eio-service`, as the ticket says. The
ticket's "six framework specs" is stale by one: `framework/ocaml/sol-outbox/sol-outbox.md`
exists too (FEAT-124), so the manifest now covers **seven** — leaving it out would have
re-created exactly the drift risk this ticket is about. Its `## Public API` already
matched `sol_outbox.mli`.

### Real drift, fixed (5 declarations)

- `sol-fn.md`: `Make.run` still showed the pre-`Sol_env.timed` environment
  (`env:< net : _ Eio.Net.t; ...; .. >`); `type trigger` had lost its first
  constructor's leading `|`.
- `sol-obs.md`: `type level = Obs_eio.level = ...` had lost the re-export's leading `|`.
  The ticket anticipated the re-export might have no `.mli` declaration to match; the
  `.mli` does declare it, so the doc copies it and the guard stays a strict text
  comparison.
- `sol-jobs.md`: `enqueue` predated `?dedupe_key`; `run` predated
  `?terminal_retention_s`/`?sweep_interval_s` and qualified `retry_policy`/`run_error`
  with `Sol_jobs.` where the `.mli` does not.

`sol-worker.md`'s claimed drift did not reproduce: its `## Module types` and
`## Entrypoints` already match `worker.mli` declaration for declaration, which is why
mapping them makes the guard pass.

### Exclusions, named and justified in the guard

Sixteen sections carry an `ocaml` block that is not the package's declaration surface —
application examples, implementation sketches, an external package's `push`
(`sol-fn.md` documents `Obs_prometheus.push`), and `sol-jobs.md`'s `## Module type`,
which mixes the skipped `JOB` module type with an app's own `t` example. Each is listed
in `EXCLUSIONS` with its reason.

### Checks

- `bash internal/tooling/scripts/verify.sh always` — 0/9 members failed.
- `python3 internal/ci/always/test_framework_doc_signatures.py` — 15 cases (was 6).
  Every manifest entry added here and both new guard branches are mutation-covered,
  each mutation verified to fail the guard for its own reason.
- `bash internal/ci/check_no_comments.sh` — pass.
- `soldev pipeline validate` — all tickets readable.

### Demo/example and language parity

Not applicable — a doc-drift guard over the framework specs; no app-author surface and
no application-facing contract change.
