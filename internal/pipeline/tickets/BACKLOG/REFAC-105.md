---
id: REFAC-105
type: refactor
severity: low
title: Make the pluto example self-contained — no target may reference internal/
source: internal/pipeline/audits/2026-09-25_organization_proposal.md, rule 1
---

**Depends on:** None.

**Premise verified (2026-09-25):** `examples/pluto/sol/dev/aws/us-east-1.yml` and `examples/pluto/sol/customer_cloud/aws/us-east-1.yml` set `terraform_var_file: ../../../../../internal/qualification/aws/smoke-test.tfvars`, and `docs/guides/TUTORIAL.md:441` tells users to run `sol deploy customer_cloud/aws/us-east-1`. Qualification docs also direct operators to write an untracked `examples/pluto/sol/qual/aws/us-east-1.yml` (`docs/qualification/run8-aws-target.example.yml`), so internal qualification uses the example as its workspace.

## Remediation

- Give the user-facing pluto targets their own var file inside `examples/pluto/`, or none at all, so the example runs from a copy of `examples/pluto/` alone.
- Decide whether the `dev` and `customer_cloud` targets are user examples or qualification fixtures. Qualification-only targets move to `internal/qualification/` (or `internal/fixtures/`), and the qualification harness points at them there.
- Add a CI guard: no file under `examples/` references `internal/`.

## Acceptance criteria

- `rg -n 'internal/' examples/` returns nothing, and the new guard fails when a reference is added (mutation test).
- **Demo/example:** pluto and `docs/guides/TUTORIAL.md` still work as written. State how that was checked.

## Completion notes (required)

- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.
