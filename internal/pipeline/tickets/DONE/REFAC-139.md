---
id: REFAC-139
type: refactor
severity: low
title: Thin cli/bin -- a command parses, calls the library, and renders; decisions move into cli/lib with tests
source: pattern audit of the REFAC-104..130 series (2026-09-26); REFAC-117 set the pattern for sol alert
---

**Depends on:** REFAC-130, REFAC-133, REFAC-135.

## The problem

REFAC-117 moved `sol alert test`'s payload and send outcome into `cli/lib` with unit tests, leaving the command to parse and render. The other large commands still hold their decisions in `cli/bin`, where only real-binary tests can reach them. `wc -l cli/bin/*.ml` (2026-09-26): `cmd_cloud_tf.ml` 1,844; `cmd_deploy.ml` 1,165; `cmd_migrate.ml` 1,161; `cmd_local.ml` 1,023.

## Remediation

For each of those four commands: identify what is a decision (what to run, in which order, what an outcome means) as opposed to argument parsing and rendering, move the decisions into the matching `cli/lib/<domain>` module, return a typed outcome, and render it in the command, as `Sol_cli_alert_test` does. Do it after REFAC-130/133/135, which change the same code paths and would otherwise conflict.

## Acceptance criteria

- Each of the four files is at most a few hundred lines of Cmdliner terms, `let*` composition and rendering; the completion notes give the before/after `wc -l` and name what moved where.
- Each moved decision has a unit test in `cli/test`.
- Output and exit codes unchanged (existing real-binary rules and the offline lifecycle harness).
- Demo/example: not applicable (internal). Language parity: no impact.

## Completion notes

**Premise verified (2026-09-27):** `wc -l cli/bin/cmd_{cloud_tf,deploy,migrate,local}.ml` on `main` before part A gave 1,839 / 1,180 / 1,022 / 1,042 (REFAC-130..135 had moved them slightly since filing). Decisions such as the deploy's omission rules, the migration Job, the local releases and the cloud lifecycle wiring were still inline in `cli/bin`.

**Landed in six PRs, each green on its own head:**

| Part | PR | What moved where |
|---|---|---|
| A | #609 | The in-cluster migration Job (submit, wait with INFRA-040's fail-fast, logs, evidence, cleanup) → `Sol_cli_migration_job`. `sol migrate apply` and the deploy gate used two drifted ~200-line copies; `apply` now fails fast on an unstartable container too, and passes `KUBECONFIG`. |
| B | #610 | The local infra releases, their pins and values → `Sol_cli_local_platform` (data). `.gitattributes` stopped union-merging dune files: it had silently produced a broken `cli/test/dune` three times. |
| C | #611 | Deploy selection (scope, `--image-ref`, target declared, DEC-041 omission, emptied selection) and the plan (GitOps + `kubernetes-live` refusal, profile preflight) → `Sol_cli_deploy_selection`. The migration gate → `Sol_cli_migration_gate`, so `sol deploy` no longer depends on `Cmd_migrate`. |
| D | #614 | `sol cloud`'s apply/destroy deps, plan and destroy-preview flows → `Sol_cli_cloud_wiring`; INFRA-076's rule → `Sol_cli_state_guard.verdict`; INFRA-042's recovery → `Sol_cli_platform_teardown` (pure readers); the var-file lookup and strict target → `Sol_cli_terraform_vars`. |
| E | #615 | `sol deploy`'s apply path (lease-bracketed attempt, event, markers, DEC-037 release record, retention) and the gate's rendering inputs → `Sol_cli_deploy_run`. |
| F | this PR | The k3d cluster → `Sol_cli_local_cluster`; port-forwards + summary as one `Sol_cli_local_platform.endpoints` list; `sol local run`'s shell lines → `Sol_cli_local_run`. |

**`wc -l`, before → after:** `cmd_cloud_tf.ml` 1,839 → 593; `cmd_deploy.ml` 1,180 → 688 (about 310 are Cmdliner terms); `cmd_migrate.ml` 1,022 → 416; `cmd_local.ml` 1,042 → 519. `cmd_deploy.ml` is the largest that remains, and what it holds is argument parsing, request resolution into `Sol_cli_deploy_run.context`, and rendering.

**Tests:** new `test_migration_job`, `test_local_platform`, `test_deploy_selection`, `test_migration_gate`, `test_cloud_command`, `test_deploy_run`; `test_local_run` extended. Output and exit codes held by the existing real-binary rules and `internal/ci/test_cloud_lifecycle_offline.sh`, which passes on every part.

**Guards:** `check_publisher_deployer_boundary.sh` now covers `cli/lib/cloud` (the provisioner) and `sol_cli_deploy_{selection,run}.ml` (the deployer), each with a mutation case. Moving the deployer's code into the library made one pre-existing crossing visible: from a checkout, `sol deploy`'s migration check builds and pushes the runner image. That is filed as **SEC-011** (BACKLOG, needs a decision), not changed here.

**Behaviour change, one:** omission notes are printed only for a deploy that proceeds; a run the target then refuses no longer prints notes about a deploy that will not happen.

**Demo/example:** not applicable (internal refactor). **Language parity:** no impact.
