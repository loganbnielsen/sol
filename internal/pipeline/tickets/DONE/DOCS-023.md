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

## Completion notes (2026-09-26)

Premise re-checked on `origin/main` (`537a5292`): `ls docs/` still listed `audits`, `dogfood`, `planning` and `qualification`, and `contract/` existed. The probe (`test -f docs/reference/runtime.md`) failed, so the premise held. Before moving qualification paths, checked that no attempt was in flight: `pgrep -af 'live-qual|live-smoke|terraform'` printed nothing, and the only qualification worktree (`sol-qual9`) held only an untracked target directory.

**Moves** (all `git mv`, so history follows):
- `contract/{README,runtime,substrate}.md` → `docs/reference/`. `contract/README.md` *became* `docs/reference/README.md`, the concept table included, so there was nothing to fold into. `contract/` is gone.
- `docs/audits/*` → `internal/pipeline/audits/`; `docs/dogfood/DOGFOOD.md` → `internal/pipeline/dogfood/`.
- Qualification now has one home, `internal/qualification/`:
  - `records/`: the 16 dated run records;
  - `aws/`: the run procedure, the AWS matrix and the run-8 target example;
  - `gcp/`: the bootstrap inventory and the GCP matrix `.md`/`.tsv`;
  - the top level: `README.md` (the ledger), `run-record-template.md`, and `scrub-whoami-capture.sh` and `transport/` from `internal/pipeline/qualification/`.
- `docs/planning/ROADMAP.md` → `docs/ROADMAP.md`; `docs/planning/{WORK_SUMMARY,OPAM_FOUNDATION_TRACKER,LIVE_DEV_DEPLOY_ROADMAP}.md` → `internal/planning/`; `docs/architecture/contributing-map.md` → `internal/contributing-map.md`.
- New: `internal/specs/framework-conventions.md`. It is an index of the DEC-022 conventions, and each row links the spec or reference section that defines it rather than restating it. Before writing, I checked the claims it summarizes (worker `SIGTERM` handling, `traceparent` on produced messages, metric names) against the package specs.

**References:** one ordered, single-pass rewrite of every literal old path across tracked files (214 files, including CI scripts, `.github/workflows/ci.yml`, the qualification harnesses and `AGENTS.md`'s Documentation Protocol and ledger reference). Kept deliberately:
- `internal/pipeline/audits/2026-09-25_organization_proposal.md` and this ticket's own Remediation. They record the plan, and a blanket rewrite turned their "old → new" lines into "new → new". Both were restored from `main`.
- Remaining `rg -n --hidden -g '!.git' -e docs/audits -e docs/dogfood -e docs/planning` hits are historical: DONE tickets' `source:` lines naming the deleted `POST_DOGFOOD_GAMEPLAN.md`, dated WORK_SUMMARY entries, DEC-046's text, and the proposal. `contract/runtime|substrate|README` and `docs/qualification` / `internal/pipeline/qualification` return nothing.

**Links:** a checker over every tracked `.md` resolved each relative link target. Before the change, 7 were broken; after it, 0 are newly broken, and 6 of the 7 pre-existing ones got fixed along the way (`docs/reference/substrate.md` → `../deployment/…`, and `internal/contributing-map.md`'s links). The one left is `internal/pipeline/tickets/DONE/INFRA-063.md -> cli/sol/lib/sol_cli_kubectl.ml`, a historical path.

**Checks run locally** (all exit 0): `check_qualification_transport.sh`, `test_qualification_transport_check.sh`, `test_scrub_whoami_capture.sh`, `internal/qualification/gcp/test-verify-matrix.sh`, `test_classify_changes.sh`, `check_no_account_artifacts.sh`, `check_public_cloud_lifecycle.sh`, `check_cert_manager_readiness.sh`, `check_platform_component_drift.sh`. Also `internal/qualification/gcp/test-live-qual.sh` (124 passed), `bash -n` on the rewritten harness scripts, `dune test cli/ --force` (59 suites), and `internal/ci/check_ocamlformat.sh --all`. The rewrite lengthened one OCaml string (`sol_cli_env_target.ml`'s pointer to `docs/reference/substrate.md`), and the first CI run failed its format check on it; `dune fmt` fixed it. The classifier treats `*.md` anywhere as docs-only, so moving Markdown into `internal/` changes no CI routing.

- Demo/example: not applicable (documentation layout).
- Language parity (DEC-022): no framework behaviour changed. The new conventions page is the parity reference itself.
