---
id: CODEX_STYLE_AUDIT-078
type: refactor
severity: low
title: Reuse observability options at the sol open command boundary
source: internal/pipeline/audits/2026-09-28_parameter_lint.md
---

Reuse observability options at the sol open command boundary

**Depends on:** None.

**Premise verified (2026-09-28):** Read `cli/bin/cmd_open.ml:15,60`,
`cmd_logs.ml:91,476` and `cmd_status.ml:536`. `Cmd_open.run` still accepts
`explicit_backend`, `explicit_base_domain` and `grafana_base_url` separately,
and its Cmdliner adapter forwards those three settings individually. Logs/status
already group this observability destination concept in
`Cmd_logs.observability_options`.

**Related:** REFAC-089 (existing observability grouping), REFAC-152 (retained
independent argument inventory). Consumer hooks are separately owned by REFAC-155.

## Problem

`Cmd_open.run` mixes command selection (`kind`, scope, links and target) with
three pieces of one telemetry-destination configuration. Logs and status have
already named that concept, while `open` still transports it as positional
fragments. This is a contextual review finding below the automated linter's
count threshold, not a claim that every seven-argument function needs a record.

## Remediation

- Accept the existing `Cmd_logs.observability_options` value at the `open`
  controller boundary; keep view, scope, links and target independent.
- Construct that value once in a Cmdliner term using the existing backend,
  base-domain and Grafana URL flags. Set the unrelated Loki fields to `None`,
  following the existing subset construction in `status_observability_term`.
- Read the grouped fields when resolving backend/base-domain and the Grafana
  URL override. Preserve current precedence and errors.
- Do not use the full logs options term: it would expose unused Loki flags.
  Do not add a new generic options abstraction or change the CLI flag surface.

## Acceptance criteria

- `Cmd_open.run` receives the existing observability options value rather than
  the three separate settings; its term constructs the value once.
- Logs, metrics and dashboard views preserve scope selection, target resolution,
  URL precedence and `--links` behavior.
- Focused command-boundary checks cover the three existing override flags and
  confirm unused Loki flags are not accepted. Existing open/observability URL
  tests pass.
- Record the demo exemption in completion notes: this changes controller
  plumbing only, and the existing runnable `sol open` examples remain valid.
- Record no language-parity impact in completion notes: shared CLI argument
  transport changes no application or framework contract.
