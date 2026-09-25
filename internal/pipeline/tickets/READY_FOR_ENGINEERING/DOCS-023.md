---
id: DOCS-023
type: docs-finding
severity: medium
title: Make docs/ user-facing only — contract into docs/reference, maintainer records into internal/
source: internal/pipeline/audits/2026-09-25_organization_proposal.md, rules 1 and 5
premise: "test -f docs/reference/runtime.md"
---

**Depends on:** DEC-046.

**Premise verified (2026-09-25):** `ls docs/` shows `audits`, `dogfood` and `qualification` beside the user guides. `internal/pipeline/` has `audits/`, `dogfood/` and `qualification/`, and `internal/qualification/` exists too. `contract/` holds `runtime.md` and `substrate.md`, which are user-facing reference (the app runtime contract and the self-hosted substrate).

## Remediation

- `contract/{runtime,substrate}.md` → `docs/reference/`. Fold `contract/README.md`'s concept table into `docs/reference/README.md` and remove `contract/`.
- `docs/audits/*` → `internal/pipeline/audits/`, and `docs/dogfood/*` → `internal/pipeline/dogfood/`.
- Merge `docs/qualification/`, `internal/pipeline/qualification/` and `internal/qualification/` into `internal/qualification/{aws,gcp,records}/`. Update the ledger references in `AGENTS.md` ("Tickets are for work that can finish") and `internal/pipeline/audits/QUALIFICATION_STATUS.md`.
- Write `internal/specs/framework-conventions.md`: the cross-language conventions from DEC-022 (schema-registry conventions, Confluent wire format, W3C trace propagation, retry/DLQ semantics, metric/label vocabulary, lifecycle/shutdown, config/secrets, job semantics). Link to each package spec that implements them. Per-package specs stay beside their code.
- Apply DEC-046's answers:
  - `docs/planning/ROADMAP.md` → `docs/ROADMAP.md`.
  - `docs/planning/{WORK_SUMMARY,OPAM_FOUNDATION_TRACKER,LIVE_DEV_DEPLOY_ROADMAP}.md` → `internal/planning/`.
  - `docs/architecture/contributing-map.md` → `internal/contributing-map.md`.
  - `docs/architecture/` otherwise stays.
- **`AGENTS.md`'s *Documentation Protocol*** names `docs/planning/ROADMAP.md` and `docs/planning/WORK_SUMMARY.md` as startup reads and the end-of-task update target. Update both paths, plus every ticket template's "Update `docs/planning/WORK_SUMMARY.md`" completion line in `READY_FOR_ENGINEERING/`.

## Acceptance criteria

- Every directory under `docs/` is written for someone using Sol.
- Qualification records, audits and dogfood runs each have exactly one home.
- `rg -n --hidden -g '!.git' '<old path>'` returns nothing outside dated historical records, for each moved path.
- Relative links in moved files still resolve. Use a link check, or `rg` for `](../` in moved files, checking each target.

## Completion notes (required)

- Demo/example: not applicable (documentation layout) — state it.
- Language parity (DEC-022): the conventions doc is the parity reference itself; state that no framework behaviour changed.
