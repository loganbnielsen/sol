---
id: REFAC-152
type: refactor
severity: medium
title: Replace loose parameter swarms with explicit domain inputs
source: Logan code review (2026-09-27), generalized from REFAC-145
---

Replace loose parameter swarms with explicit domain inputs

**Depends on:** None.

**Premise verified (2026-09-27):** REFAC-145 found 20/21-argument Deployment and
Rollout builders in `sol_cli_manifest.mli`. The style-audit sweep also found the
27-argument internal retry-topic consumer in
`kafka_service_retry_topics.mli`. These are positive controls for the broader API shape,
not an exhaustive inventory.

## The principle — explicit domain grouping

When several arguments travel together as one real concept, represent that concept with
a named record or variant and validate it before the call. Labels make a long call
legible but do not let the compiler ensure that related paths receive the same value.

Do not replace every long signature with a vague `deps` bag. Keep labels when inputs are
few and independent; use a record for a real request/spec/config/runtime value, a variant
when valid fields differ by mode, or split the function when the arguments belong to
sequential phases.

## Remediation

- Audit public `.mli` files first, then widely used internal functions across
  `cli/lib/deploy`, `cli/lib/workspace`, `cli/lib/cloud`, `framework/ocaml`, and
  `internal/tooling` for more than five or six primitive/config-fragment arguments.
- Trace every caller before choosing labels, a domain record, a mode-specific variant,
  or a phase split.
- Include repeated optional/defaulted arguments: a long optional list is still a swarm
  when callers must remember one invariant across several paths.
- Reuse existing domain types before introducing a new one.

## Acceptance criteria

- Completion notes inventory every public signature above the threshold with a verdict:
  already cohesive, grouped, variant/split, or deliberately retained.
- High-confidence swarms become named domain values or phase boundaries; no vague
  dependencies record is introduced.
- Callers construct each domain value once and share it across paths that must agree.
- Focused tests prove the invariant the new type makes unrepresentable or single-source.
- Demo/example and language-parity impact are recorded per changed API.

