---
id: REFAC-149
type: refactor
severity: low
title: Eagerly normalize non-trivial arguments before application
source: Logan code review (2026-09-27), generalized from cmd_assets check calls
---

Eagerly normalize non-trivial arguments before application

**Depends on:** REFAC-148.

**Premise verified (2026-09-27):** manual review of `cmd_assets.ml` on `origin/main` at
`52c01e21` found both representative shapes: a multi-line `let*` chain and a multi-arm
`match` embedded as the second argument to `check`. A repository seed search
(`rg -n -U '\([[:space:]]*(match|if|try)\b|\n[[:space:]]+\((match|if|try)\b' --glob '*.ml' cli framework examples internal`)
also finds candidates in `sol_cli_rollout_diagnosis.ml`, `sol_jobs.ml`, `peer.ml`, and
`soldev_merge.ml`; the expression search is deliberately broad and is not itself a
finding.

## The principle — eager argument normalization

Resolve, validate, default, and bind non-trivial expressions or domain constraints
before passing them to higher-order functions, constructors, or terminal-effect
handlers. An outer call should expose its operation and normalized arguments without
making the reader hold that call open across a non-trivial `match`, `if`, `try`, Option
unwrap, Result pipeline, fallback, or transformation. This is about top-to-bottom
evaluation order and fail-fast invariants, not banning expressions as arguments.

Inline control flow stays when it is one short arm, a familiar constructor expression,
or naming it would add indirection without making the outer operation clearer.

## Remediation

- Add this distinction to `CONTRIBUTING.md`: non-trivial argument production is a named
  step; trivial expressions remain inline.
- Manually inspect the whole OCaml tree, including examples, scaffold templates, tests,
  and internal tooling. Grep seeds candidates only.
- Refactor high-confidence sites so the outer application reads in one pass. Reuse
  REFAC-148's Result pipeline rule where the nested expression only forwards errors.
- Normalize trust-boundary and domain inputs before terminal rendering/effects so those
  calls receive values that are already valid for their operation.
- Do not introduce helpers used once when a local `let` is enough.

## Acceptance criteria

- The manual sweep covers `cli/`, `framework/ocaml/`, `examples/`, platform scaffold
  templates, and `internal/tooling/`; completion notes name folders and representative
  changes.
- Multi-line control flow is not embedded in an application when resolving it first
  materially clarifies the outer operation.
- Retained representative shapes are documented so this does not become an absolute
  formatting prohibition.
- Behavior and output remain unchanged, with focused tests for changed decision paths.
- Demo/example and language-parity impact are recorded per changed surface.

## Completion (2026-09-28)

- Rechecked against origin/main after REFAC-148: asset checks now expose planning
  decisions, but command exit callbacks, migration log redaction, cloud teardown
  evidence, and rollout diagnostics still embed non-trivial argument production.
- Reviewed cli/bin, all six cli/lib domains, framework/ocaml, examples, scaffold
  templates, tests, and internal/tooling using the manual folder sweep and callers.
- Changes pre-bind command destination/request resolution before exit conversion,
  available-domain errors, plan type suffixes, redacted migration logs, platform
  backend/workdir, teardown completion text and observed-state evidence, rollout
  diagnostic suffixes, authenticated/traced peer headers, decode disposition log
  messages, and soldev's review-summary fallback.
- Retained familiar Option defaults, short constructor literals, Cmdliner combinators,
  lazy authentication refresh branches, short-circuit job stop checks, and simple
  optional descriptors: binding those would add indirection or change evaluation.
- Validation: CLI/framework/soldev builds, formatting, rollout-diagnosis, secret,
  config, cloud-destroy, peer, and all soldev tests pass.
- Demo/example: no behavioral change; existing Pluto/scaffold decoding already
  normalizes its inputs (REFAC-147). No language-parity impact: interfaces and
  application contracts are unchanged.
