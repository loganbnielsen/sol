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
