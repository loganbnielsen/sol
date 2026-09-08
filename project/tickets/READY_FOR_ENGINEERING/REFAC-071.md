---
id: REFAC-071
type: refactor
severity: medium
source: architecture discussion with user, 2026-09-08
---

**Depends on:** None. **Sequencing:** work this only after the current ticket queue (EXP-029, INFRA-003, INFRA-004, FRIC-010, OBS-043, AUDIT-067) is fully drained, and not concurrently with REFAC-072/073/074 — a repo-wide path move collides badly with any other open worktree branch and these four siblings touch overlapping shared docs. Work in the order 071 → 072 → 073 → 074.

Move `integrations/kafka/kafka-eio-service/` into `framework/`

## Decision

The repo's top-level directories should be organized by *who consumes the code*, not by history. Four categories: `framework/` (libraries an app's OCaml binary links against), `cli/` (the product surface + the deploy machinery it shells out to), `pipeline/` (this repo's own engineering-process record), `devtools/` (this repo's own internal dev tooling, never shipped). This ticket is the first of four moves implementing that split (see REFAC-072/073/074 for the others).

**Why this one specifically:** `kafka-eio-service` (schema registry + service orchestration) is linked by `framework/sol-worker`-generated code — it's exactly the same kind of app-linked library as `sol-svc`/`sol-worker`/`sol-fn`, just historically placed under a separate `integrations/` top-level directory because it predates `framework/` existing as a concept. There's no `integrations/` directory left in the repo once this moves (the other former `integrations/*` subdirs — storage, observability, aws — were already extracted to standalone opam packages per `~/Code/CLAUDE.md`'s per-package pinning model).

## Remediation

- `git mv integrations/kafka/kafka-eio-service framework/kafka-eio-service` (keep the findlib/library names as-is — this is a directory move, not a rename of the OCaml package).
- Remove the now-empty `integrations/` tree.
- Update every `dune`/`dune-project` reference to the old path.
- Update `.claude/CLAUDE.md`'s repo layout section, `README.md`, `docs/planning/ROADMAP.md`/`WORK_SUMMARY.md`, and any package spec doc (`kafka-eio-service.md`) that states the old path.
- Grep the whole repo for `integrations/kafka` and `integrations/` to catch anything missed (CI workflows, scripts, other `.md` docs).
- Run the full local test suite (`platform/local/scripts/run_tests.sh`) before submitting — this touches build-relevant paths for every worker-generating code path.
