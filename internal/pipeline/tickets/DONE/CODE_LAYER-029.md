---
id: CODE_LAYER-029
type: refactor
severity: medium
title: One bounded public-delegation wait, shared by deploy and bootstrap
source: internal/pipeline/audits/2026-10-02_code_layer_audit.md
premise: "rg -q '^let await_public_delegation' cli/lib/cloud/sol_cli_installation_stage.ml"
---

One bounded public-delegation wait, shared by deploy and bootstrap

**Depends on:** None.

## Problem

The "wait for the public delegation" bounded operation is implemented twice:
`cli/bin/cmd_deploy.ml:140-167` (`await_public_delegation`) and
`cli/bin/cmd_cloud_tf.ml:589-616` (inline in `cloud_bootstrap`). They print the
same banner (identical format string), compute the same
`attempts = max 1 (seconds / 5)`, call
`Sol_cli_installation_stage.await_delegation ~run ~report ~attempts
~interval:5. ~domain ()`, and map `Established`/`Unmet`/`Unknown` the same way.
The only difference is an extra `public delegation Established` line in
bootstrap.

The two also read the domain by different routes: `cmd_deploy` through
`Sol_cli_installation.zone_domain`, `cmd_cloud_tf` by matching
`Service_zone { domain; _ }`. That is exactly how one concept grows two
definitions, and it is why a bounded operation with a security-relevant
fail-closed verdict (UNKNOWN is never promoted) should not be duplicated.

Incidentally, `cli/bin/cmd_deploy.ml:355` prints
``run `sol depl       oy %s` again`` — the word `deploy` split by alignment
whitespace — in the environment-refusal guidance. Fix it in this pass.

## Remediation

1. Add one bounded helper to `Sol_cli_installation_stage`, e.g.
   `await_public_delegation ~configuration ~run ~seconds ~report
   ~on_established : (unit, string) result`, that reads the domain once (via
   the existing zone accessor), returns `Ok ()` when there is no zone or the
   wait is disabled, otherwise runs the existing `await_delegation` and maps the
   verdicts, calling `on_established` (or returning a typed verdict) so the
   caller can print its own establishment line.
2. Have `cmd_deploy.await_public_delegation` and `cmd_cloud_tf.cloud_bootstrap`
   both call it; delete the duplicated banner, attempt computation, and verdict
   match.
3. Fix the `sol depl       oy` typo.

## Acceptance criteria

- The banner format, `attempts`, `~interval:5.`, and the
  `Established`/`Unmet`/`Unknown` mapping exist once.
- `cmd_deploy` and `cmd_cloud_tf` both reach the same code; neither contains its
  own `match` over the delegation verdict.
- `--await-delegation 0` and a target with no zone still short-circuit to
  `Ok ()`; an unqueryable resolver still yields an error carrying the unknown
  reason (UNKNOWN is never a silent success).
- `cli/test/inline/test_installation.ml` (and any delegation test) passes; add a
  case for the shared helper if none exists.
- `rg -n 'sol depl +oy' cli/bin/cmd_deploy.ml` returns nothing.
- Update a runnable example/demo for application-facing behavior, or record why
  this is an internal-only refactor.
- Record the per-language capability verdict for framework/application
  contracts, or explain why language parity is unaffected.

## Completion (2026-10-02)

- **Premise re-verified** at `origin/main` `8cb09659`: the wait was duplicated in `cmd_deploy.ml` and `cmd_cloud_tf.ml` and the two read the domain by different routes; the `sol depl       oy` typo was present at `cmd_deploy.ml:355`.
- **Fix.** Added `Sol_cli_installation_stage.await_public_delegation ~configuration ~run ~seconds ~report ~on_established`: it reads the domain once through `Sol_cli_installation.zone_domain`, computes `attempts = max 1 (seconds / 5)`, emits the banner and indented attempt lines through `report`, runs the existing `await_delegation` with `~interval:5.`, maps `Established` to `on_established` and `Unmet`/`Unknown` to `Error`, and short-circuits when there is no zone or the wait is disabled. Both callers use it; bootstrap's extra "Established" line is its `on_established` callback. Fixed the typo.
- **Tests.** Three new `cli/test/inline/test_installation.ml` cases: a zero-second wait is `Ok ()` without querying the resolver or establishing; an answering resolver reports the banner and runs the establishment hook once; an unqueryable resolver returns its own reason and never establishes. The existing `await_delegation` cases still pin the inner loop. Full inline suite passes.
- Validation: full `dune build`; `dune fmt` clean; `rg -n 'sol depl +oy' cli/bin/cmd_deploy.ml` returns nothing.
- **Demo/example: not applicable** — the CLI's own first-run guidance. **Language parity: no impact.**
