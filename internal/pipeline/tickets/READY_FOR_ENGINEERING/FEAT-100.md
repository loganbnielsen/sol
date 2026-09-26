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

Implement DEC-047 as decided **and as amended on 2026-09-26** (an optional gitignored `sol/environments.local.yml`, keys disjoint from the tracked file, which may add whole environments/targets but never change tracked ones; `check_no_account_artifacts.sh` refuses it tracked; the qualification harnesses write it instead of `sol/qual*/` target files): `sol/environments.yml`, sticky `omit`, existing flat key names, and **DEC-047's key-placement and merge table as the spec**. Parse the environments file, merge `sol.yml` → environment → target with lower layers winning, and remove per-target file discovery (`discover_target_paths`, `relative_target_file` in `Sol_cli_config`). Pre-alpha, so no compat shim: an old `sol/<env>/<provider>/<region>.yml` layout is refused with a message naming the new file.

Also update `sol new` scaffolding and `sol.yml`/target references in `contract/substrate.md` (or `docs/reference/` after DOCS-023), `docs/guides/TUTORIAL.md`, `docs/deployment/` and the scaffold templates.

## Acceptance criteria

- `sol deploy prod/aws/us-east-1`, `sol plan` and `sol cloud plan|apply|destroy` resolve the same targets as before, from the new file.
- Tests cover the precedence (a target key overriding an environment key, and an environment key overriding `sol.yml`), and each row of DEC-047's table: `scale` deep-merge, provider-block deep-merge, sticky `omit`, target-only keys rejected at environment level, app-shape keys rejected outside `sol.yml`, and an undeclared service or resource rejected.
- Pluto's four target files become one environments file, and env-wide keys are declared once.
- **Demo/example:** pluto and `docs/guides/TUTORIAL.md` are updated; `sol new` scaffolds the new file.

## Completion notes (required)

- Language parity (DEC-022): state "no language-parity impact" and why.
- Update `docs/planning/WORK_SUMMARY.md`.
