---
id: REFAC-109
type: refactor
severity: low
title: Rename Sol_cli_config's overloaded t / target / target names
source: operator code-review notes (2026-09-26), cli/lib/workspace/sol_cli_config.ml
---

**Depends on:** FEAT-100.

## The problem

`Sol_cli_config` has a resolved-configuration type `t` with a field `target` of type `target`, and an accessor `Sol_cli_config.target : t -> target option`. A reader sees `target cfg`, `cfg.target` and `(target : target)` and can't tell the whole resolved config from the deploy destination inside it. It's correct at runtime, but costly to read.

## Remediation

- Rename for meaning. Proposed: the resolved config `t` → `resolved`; the `target` record → `destination`, since it says where and how a workload is deployed; and the accessor to match. Choose the final names in this ticket's first commit, and update every call site (pre-alpha, no aliases).
- Do it after FEAT-100, which restructures this module's resolution code, so the rename happens once.

## Acceptance criteria

- No type and value in `Sol_cli_config`'s interface share the name `target`.
- **Demo/example:** not applicable (internal); state it.

## Completion notes (required)

- Language parity (DEC-022): no application-facing impact.
