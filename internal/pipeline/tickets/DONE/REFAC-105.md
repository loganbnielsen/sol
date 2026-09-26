---
id: REFAC-105
type: refactor
severity: low
title: Make the pluto example self-contained — no target may reference internal/
source: internal/pipeline/audits/2026-09-25_organization_proposal.md, rule 1
---

**Depends on:** None.

**Premise verified (2026-09-25):** `examples/pluto/sol/dev/aws/us-east-1.yml` and `examples/pluto/sol/customer_cloud/aws/us-east-1.yml` set `terraform_var_file: ../../../../../internal/qualification/aws/smoke-test.tfvars`, and `docs/guides/TUTORIAL.md:441` tells users to run `sol deploy customer_cloud/aws/us-east-1`. Qualification docs also direct operators to write an untracked `examples/pluto/sol/qual/aws/us-east-1.yml` (`internal/qualification/aws/run8-aws-target.example.yml`), so internal qualification uses the example as its workspace.

## Remediation

- Give the user-facing pluto targets their own var file inside `examples/pluto/`, or none at all, so the example runs from a copy of `examples/pluto/` alone.
- Decide whether the `dev` and `customer_cloud` targets are user examples or qualification fixtures. Qualification-only targets move to `internal/qualification/` (or `internal/fixtures/`), and the qualification harness points at them there.
- Add a CI guard: no file under `examples/` references `internal/`.

## Acceptance criteria

- `rg -n 'internal/' examples/` returns nothing, and the new guard fails when a reference is added (mutation test).
- **Demo/example:** pluto and `docs/guides/TUTORIAL.md` still work as written. State how that was checked.

## Completion notes (required)

- Language parity (DEC-022): no application-facing impact — state it.
- Update `internal/planning/WORK_SUMMARY.md`.

## Completion notes

- **Premise re-verified (2026-09-25, `origin/main` `fd28cfc7`):** both pluto targets still set `terraform_var_file: ../../../../../internal/qualification/aws/smoke-test.tfvars`.
- **The `dev` and `customer_cloud` decision:**
  - `customer_cloud` is a user example; the tutorial deploys to it.
  - `dev` was acting as the AWS smoke fixture, since `live-smoke.sh` defaulted to it.

  Both are now user-shaped: `pluto-dev` / `pluto-customer` clusters on `*.pluto.example.com`, with no var file. `dev` keeps its cluster-and-platform-only omits.
- **The smoke fixture moved to the harness.** `internal/qualification/aws/live-smoke.sh` now writes an untracked `sol/qual2/aws/us-east-1.yml` into its workspace. That path is one `check_no_account_artifacts.sh` already refuses to see tracked. The file has the old smoke shape and an **absolute** `terraform_var_file`, and it's removed on exit, the same pattern as the GCP harness's `sol/qual/` target. `WORKSPACE` and `TARGET` stay overridable.
- **Verified offline.** `write_target` was extracted from the harness and run against a scratch copy of pluto. `sol target show --target …` then resolved all three targets:
  - `qual2/aws/us-east-1` → cluster `sol-smoke-x`, `smoke-test.invalid`;
  - `dev` → `pluto-dev`;
  - `customer_cloud` → `pluto-customer`.
- **Guard.** `internal/ci/check_examples_self_contained.sh`, with the mutation test `test_examples_self_contained.sh`, is wired unconditionally into CI.
  - **Scope:** configuration and build inputs under `examples/` (YAML/JSON/TOML/tfvars/dune/opam/Dockerfile/shell). Those decide whether a copied example runs.
  - **Deviation from the acceptance criterion, deliberately:** the criterion said `rg -n 'internal/' examples/` should return nothing. That would also forbid prose and comments that merely *mention* `internal/`, such as `examples/README.md` pointing maintainers at fixtures or `demo_ts` port comments naming their OCaml source. Those can't break a copy.
  - **Positive control:** restoring the old `dev` target fails the check at `examples/pluto/sol/dev/aws/us-east-1.yml:6`.
- **Two pre-existing defects found:**
  1. **`live-smoke.sh` on `main` did not parse.** `bash -n` failed with "unexpected EOF while looking for matching `}'", because of an apostrophe inside `${CLUSTER:?Set CLUSTER to the target's EKS cluster name}`. That's the pitfall `live-qual.sh` documents. Fixed here, since the harness has to run for this change to mean anything. It dates from #311.
  2. **A relative `terraform_var_file` resolves against the invocation directory, not the workspace or the target file.** `cmd_cloud_tf.ml`'s `normalize_var_file` concatenates it with `Sys.getcwd ()`. From `examples/pluto`, the old path resolved to `/home/logan/internal/qualification/aws/smoke-test.tfvars`, which doesn't exist; from the target file's own directory it resolved correctly. So pluto's `dev` target had a var file that could never have loaded when run from the workspace. This change removes that reference but not the resolution bug, which is filed separately as a bug ticket.
- **Tests:** `dune build` and `dune test cli/sol/test/` pass (0 `[FAIL]`); every `internal/ci/test_*.sh` passes; `check_no_account_artifacts`, `check_public_cloud_lifecycle` and `check_qualification_transport` pass.
- **Demo/example:** pluto and `docs/guides/TUTORIAL.md` still work as written. The tutorial's `sol deploy customer_cloud/aws/us-east-1` address is unchanged and now resolves to a user-shaped target.
- **Language parity (DEC-022):** no application-facing impact; this is example configuration and qualification tooling.
