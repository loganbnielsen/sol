# internal/

Repository machinery that maintainers need but that does not explain the
product. Nothing here is part of the public Sol lifecycle or the application
contract.

| Directory | What it owns |
| --- | --- |
| [`ci/`](ci/) | CI guardrails, the change classifier, and their mutation tests. Invoked by `.github/workflows/` and the pre-commit hook. |
| [`qualification/aws/`](qualification/aws/) | Live AWS qualification: the smoke harness, the smoke Terraform var file, the IAM policy, and the provision/teardown scripts. May exercise the public `sol` lifecycle; may never implement it with Terraform/Helm. |
| [`pipeline/`](pipeline/) | The work-tracking system: `tickets/` (BACKLOG/READY_FOR_ENGINEERING/DONE), dated `audits/`, and `dogfood/` runs. |
| [`tooling/`](tooling/) | Maintainer tooling: `soldev` (the internal pipeline CLI), `sol_process`, the git `hooks/`, the `perf/` baseline, and `scripts/` (the test runner `run_tests.sh`, `perf.sh`, `install-hooks.sh`, `prove-workspace-independence.sh`). |
| [`fixtures/`](fixtures/) | Test fixtures that are not user-facing examples (the OCaml-only worker workspace, the e2e demo library). |

Placement follows the organization rules in [`../AGENTS.md`](../AGENTS.md)
(DEC-046). The one that defines this directory: **`docs/` is for people using
Sol; `internal/` is for people building Sol.** Maintainer-only material belongs
here even when it's prose.

Product code lives in [`../cli/`](../cli/), [`../framework/`](../framework/),
and [`../contract/`](../docs/reference/); user-facing examples live in
[`../examples/`](../examples/).
