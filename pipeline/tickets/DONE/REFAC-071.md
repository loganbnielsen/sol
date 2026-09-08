---
id: REFAC-071
type: refactor
severity: medium
source: architecture discussion with user, 2026-09-08
branch: REFAC-071/kafka-eio-service-to-framework
worktree: ../sol-REFAC-071-kafka-eio-service-to-framework
pr: https://github.com/loganbnielsen/sol/pull/160
---

**Depends on:** None.

**Sequencing note:** the earlier queue (EXP-029, INFRA-003, INFRA-004, FRIC-010, OBS-043, AUDIT-067) has already drained as of 2026-09-08 (INFRA-004 skipped for lack of AWS credentials, OBS-043 returned to BACKLOG for an unresolved decision gate — neither is a real dependency of this ticket). This is the first of four sequenced moves; REFAC-072/073/074 each declare a real `Depends on` pointing at the previous one in the chain, so the pipeline tooling enforces the order automatically. Do not work any of the four concurrently — each is a repo-wide path move touching overlapping shared docs.

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

## Review — automated checks passed
Wide-blast-radius kafka-eio-service move verified thoroughly: build clean, integrations/ grep shows only historical/dated/excluded references, sol new workspace tested end-to-end (single vendor/framework symlink resolves correctly, generated workspace builds), release.yml bundle changes sound, deletion of integrations/Makefile confirmed unreferenced (platform/local/Dockerfile deletion left one dangling comment in an already-fully-dead orphaned demo subtree predating this ticket, not a regression), full local test suite independently re-run and passes including kafka-eio-service's own suite from its new location.

## CI regression found post-review (2026-09-08)

PR #160's actual GitHub Actions run failed on the "Unit tests (no broker/Postgres/Loki required)" step (run 34270242355, job 102209716354): `framework/kafka-eio-service/test/test_kafka_service_integration.exe`'s `schema_check`/`roundtrip`/`consume_partitioned`/`error_handling` tests all fail with `Connection refused` against `tcp:[::1]:8081`/`tcp:[::1]:9092`. Root cause: `run_unit()`/CI's unit-test step both run the broker-less `dune test framework/ cli/sol/test/`. Before this PR, `framework/` never contained kafka-eio-service, so this command never touched its broker-requiring integration tests. Now that kafka-eio-service lives inside `framework/`, the broad glob sweeps them in — and CI's bare "test" job has no broker. The prior review's local full-suite re-run apparently didn't catch this (likely ran with a broker already available locally, masking the gap that only shows up in CI's clean environment). Moved back to REVIEW pending a follow-up commit to the same branch fixing the test scoping.

## Fix verified, real CI green (2026-09-08)

Follow-up commit `4038550f` rescoped `run_unit()`/CI's unit-test step to `framework/`'s five non-kafka subdirs explicitly (`sol-env`, `sol-fn`, `sol-obs`, `sol-svc`, `sol-worker`) + `cli/sol/test/`, matching how `run_kafka()` already targets `framework/kafka-eio-service/` by name. Independently re-verified both directions: broker-less run genuinely excludes the integration suite (690 tests, zero connection errors, zero mentions of `kafka_service_integration`); with a broker up, both kafka-eio-service suites (unit + integration, 27 tests) still execute and pass. Diff confirmed complete (nothing in `framework/` missed or double-counted). Per this bug's own lesson, did not trust local verification alone — rechecked GitHub's actual CI run (34272969756) after the fix landed: all 6 checks green, including the previously-failing `test` job (4m56s, no failures). Promoting to READY_TO_MERGE on confirmed real-CI green, not local-only.
