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
