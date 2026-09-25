---
id: FEAT-100
type: feature
severity: medium
title: Implement the environment layer for deployment config
source: DEC-047, internal/pipeline/audits/2026-09-25_organization_proposal.md § Deployment config
---

**Depends on:** DEC-047, REFAC-105.

## Remediation

**Parser cost is in scope.** `sol.yml` is read by a hand-written subset parser (`Sol_cli_config`, six "unsupported sol.yml syntax" rejections), and the CLI has no YAML library. Either extend that parser to the environments file's shape, or adopt a YAML library for both files. Choose one, justify it in the completion notes, and don't support syntax (such as flow maps) that tests don't cover.

Implement the shape DEC-047 decides: parse the environments file, merge `sol.yml` → environment → target with lower layers winning, and remove per-target file discovery (`discover_target_paths`, `relative_target_file` in `Sol_cli_config`). Pre-alpha, so no compat shim: an old `sol/<env>/<provider>/<region>.yml` layout is refused with a message naming the new file.

Also update `sol new` scaffolding and `sol.yml`/target references in `contract/substrate.md` (or `docs/reference/` after DOCS-023), `docs/guides/TUTORIAL.md`, `docs/deployment/` and the scaffold templates.

## Acceptance criteria

- `sol deploy prod/aws/us-east-1`, `sol plan` and `sol cloud plan|apply|destroy` resolve the same targets as before, from the new file.
- Tests cover the precedence (a target key overriding an environment key, and an environment key overriding `sol.yml`), cover each key's merge rule from DEC-047's table (a deep-merge case and a replace case at minimum), and reject target-only keys placed at environment level.
- Pluto's four target files become one environments file, and env-wide keys are declared once.
- **Demo/example:** pluto and `docs/guides/TUTORIAL.md` are updated; `sol new` scaffolds the new file.

## Completion notes (required)

- Language parity (DEC-022): state "no language-parity impact" and why.
- Update `docs/planning/WORK_SUMMARY.md`.
