---
id: FEAT-100
type: feature
severity: medium
title: Implement the environment layer for deployment config
source: DEC-047, internal/pipeline/audits/2026-09-25_organization_proposal.md § Deployment config
---

**Depends on:** DEC-047, REFAC-105, REFAC-106.

## Remediation

**Parser cost is in scope.** `sol.yml` is read by a hand-written subset parser (`Sol_cli_config`, six "unsupported sol.yml syntax" rejections), and the CLI has no YAML library. Either extend that parser to the environments file's shape, or adopt a YAML library for both files. Choose one, justify it in the completion notes, and don't support syntax (such as flow maps) that tests don't cover.

Implement DEC-047 as decided **and as amended on 2026-09-26** (an optional gitignored `sol/environments.local.yml`, keys disjoint from the tracked file, which may add whole environments/targets but never change tracked ones; `check_no_account_artifacts.sh` refuses it tracked; the qualification harnesses write it instead of `sol/qual*/` target files): `sol/environments.yml`, sticky `omit`, existing flat key names, and **DEC-047's key-placement and merge table as the spec**. Parse the environments file, merge `sol.yml` → environment → target with lower layers winning, and remove per-target file discovery (`discover_target_paths`, `relative_target_file` in `Sol_cli_config`). Pre-alpha, so no compat shim: an old `sol/<env>/<provider>/<region>.yml` layout is refused with a message naming the new file.

Also update `sol new` scaffolding and `sol.yml`/target references in `docs/reference/substrate.md` (or `docs/reference/` after DOCS-023), `docs/guides/TUTORIAL.md`, `docs/deployment/` and the scaffold templates.

## Acceptance criteria

- `sol deploy prod/aws/us-east-1`, `sol plan` and `sol cloud plan|apply|destroy` resolve the same targets as before, from the new file.
- Tests cover the precedence (a target key overriding an environment key, and an environment key overriding `sol.yml`), and each row of DEC-047's table: `scale` deep-merge, provider-block deep-merge, sticky `omit`, target-only keys rejected at environment level, app-shape keys rejected outside `sol.yml`, and an undeclared service or resource rejected.
- Pluto's four target files become one environments file, and env-wide keys are declared once.
- **Demo/example:** pluto and `docs/guides/TUTORIAL.md` are updated; `sol new` scaffolds the new file.

## Completion notes (required)

- Language parity (DEC-022): state "no language-parity impact" and why.
- Update `internal/planning/WORK_SUMMARY.md`.

## Completion notes

**Premise re-verified (2026-09-26, after REFAC-106):** `Sol_cli_config` merged `sol.yml` with one per-target file, `sol/<env>/<provider>/<region>.yml`, found by `relative_target_file` / `discover_target_paths`. There was no environment layer and no local file.

**Parser.** This builds on REFAC-106's libyaml decoder rather than extending the hand-written parser; that was the operator's decision, with REFAC-106 filed and landed first. `decode_layer` decodes an environment or target body with the same key table as `sol.yml`: target keys directly in the body, next to `resources`/`services`. `project` or a nested `target:` block there is an error. Errors name their layer, e.g. `prod.targets.aws/us-east-1: …`.

**Resolution (DEC-047 as amended).**
- **Loading.** `load_environments` reads `sol/environments.yml` and the optional `sol/environments.local.yml`, refuses the old per-target layout (naming where each file goes), and applies the placement table:
  - target-only keys (`cluster_name`, `kube_context`, `kubeconfig`, `cluster_endpoint_cidr`, `registry`) are rejected at environment level;
  - app-shape keys (service `type`/`path`/`language`/`uses`, resource `type`/keys/`indexes`) are rejected outside `sol.yml`.
- **Local file.** It unions in disjointly: it may add keys the tracked file leaves unset, or whole environments and targets. A key both files set is an error naming the tracked file.
- **Merge.** `resolve` merges `sol.yml` → environment → target through the existing `merge`, which already implements the key table: lowest layer wins; `scale` and provider blocks merge per key; lists replace; `omit` is sticky. An environment or target naming a service or resource `sol.yml` doesn't declare is an error.
- **API.** "Is this target declared" replaces "does its file exist": `target_declared` and `target_source` replace `target_file` in `cmd_deploy`, `cmd_target` and `cmd_cloud_tf`. Discovery (`discover_target_paths`, used by `cmd_target` and the same-cluster check) reads the environments view.

**Proof of equivalence.** For all four pluto environments, `sol plan` output under the new `sol/environments.yml` is byte-identical to the old per-target files. The old layout was run with the REFAC-106 binary (same parser), the new with this branch's: prod 29, pilot 28, dev 21 and customer_cloud 27 lines, all identical.

**Tests** (`test_config.ml`, 11 new):
- layer precedence (`sol.yml` < environment < target);
- `scale` and provider blocks deep-merge;
- sticky `omit`;
- target-only key at environment level refused;
- app shape outside `sol.yml` refused;
- undeclared service refused;
- local file adds keys and whole environments;
- local file may not change tracked keys;
- old per-target files refused;
- `project` in an environment refused;
- declared targets discovered across both files.

Existing tests that wrote per-target files now go through `cli/test/support/Targets_fixture`, which renders the same text as a target body in `sol/environments.yml`. The four shell rules in `cli/test/dune` and the offline lifecycle harness were converted; the harness's `app_db` type moved to its `sol.yml`, with the GCP target omitting it to keep each target's resource set unchanged.

**Scaffold and demo.**
- `sol new` writes `sol/environments.yml` (a placeholder `prod` with `aws/us-east-1`) and a `.gitignore` (`_build/`, `sol/environments.local.yml`). Its message and the CI template comments name the new file.
- Pluto's four target files became `sol/environments.yml`: policy at environment level, cluster identity on targets. Pluto also gets a `.gitignore`.
- `docs/guides/TUTORIAL.md` gains an "Environments and targets" section: the layering, the placement rules and the local file.

**Qualification.**
- `live-qual.sh` (GCP) and `live-smoke.sh` (AWS) write their environment into `sol/environments.local.yml`, marked as harness-written. They refuse to overwrite a local file they didn't write and remove only their own. Both generated files were loaded with the real binary (`sol target show`, `sol plan`).
- **Found, fixed here:** `live-qual.sh` still set `terraform_var_file: ../../../../../internal/…`, which was relative to its old target file. Since BUG-057 that resolves from the workspace root, i.e. outside the repository, so the next GCP run would have failed. It now uses the harness's absolute `$TFVARS`.
- `check_no_account_artifacts.sh` refuses a tracked `sol/environments.local.yml`. Its `sol/qual*/` pattern is widened from `qual|qual2` to `qual[0-9]*`, which also covers INFRA-084's per-attempt keys (`qual9`), previously uncaught. The mutation test gained both cases plus a passing tracked `environments.yml`; the positive control (restoring the old pattern) fails it.
- The run-8 example target, run-record template, v1 matrix and agent-setup safety note name the local file.

**Also fixed.** `sol target show`'s not-declared message printed a literal `\n\n`, because its format string held `\\n\\n`.

**Verified:**
- `dune build` and `dune test cli/test/` pass (0 `[FAIL]`, including the offline lifecycle harness);
- `internal/qualification/gcp/test-live-qual.sh` passes (90 scenarios);
- the account-artifact, examples-self-contained and workflow-paths guards and their mutation tests pass;
- the format check is clean.

**Language parity (DEC-022):** deployment configuration is language-neutral. TypeScript and OCaml units resolve through the same environments; no per-language impact.
