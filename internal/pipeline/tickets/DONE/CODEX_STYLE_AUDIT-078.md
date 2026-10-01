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

## Completion (2026-10-01)

Implemented on `CODEX_STYLE_AUDIT-078/open-observability-options`, based on `main` at
`fea6e952`.

**Premise re-verified (`main` at `fea6e952`), still actionable:**

```text
$ rg -n 'let run kind|explicit_backend|explicit_base_domain|grafana_base_url' cli/bin/cmd_open.ml
29:let run kind scope_str links explicit_backend explicit_base_domain target grafana_base_url
40:      ~explicit_backend
41:      ~explicit_base_domain
47:    Sol_cli_observability_url.resolve ~backend ?base_domain ?override:grafana_base_url ()
88:         $ Cmd_logs.grafana_base_url_arg))
```

`Cmd_logs.observability_options` was already the named concept (used by `sol logs` and
`sol status`), so the grouping existed and only `open` still transported it as fragments.

**What landed.** `Cmd_open.run` now takes
`(observability : Cmd_logs.observability_options)` instead of `explicit_backend`,
`explicit_base_domain` and `grafana_base_url`, and it resolves the destination through
`Cmd_logs.backend_and_base_domain ~target observability` — the same helper `sol logs`
uses — with the Grafana override read from the grouped field. A `observability_term`
constructs the value once in the Cmdliner term from the three existing flags and sets the
unrelated Loki fields to `None`, mirroring `Cmd_status.status_observability_term`. View,
scope, `--links` and `--target` stay independent, no Loki flag became visible, and no new
abstraction was introduced.

**Command-boundary checks** are in `cli/test/test_open_options.sh` (registered as a
`runtest` rule in `cli/test/dune`): each of the three override flags is accepted, the
Grafana override actually changes the resolved URL, `sol open logs` and `sol open infra`
take the same destination flags, and `--loki-base-url`, `--loki-username` and
`--loki-password` are refused (exit 124) rather than quietly accepted. `test_open.ml`
(URL building, including the INFRA-027 cases) still passes.

**Demo exemption:** this changes controller plumbing only — no command, flag, URL or
rendered artifact changes — so no runnable example needs updating and the existing
`sol open` examples stay valid.

**Validation.** `dune build`; `dune test cli/`; `internal/ci/check_ocamlformat.sh --all`,
`check_no_comments.sh`, `check_result_syntax.sh`, `check_cli_reference.py` (page unchanged,
as expected: the flag surface did not move), `check_test_reachability.py`,
`check_provider_dispatch.sh`, `check_library_output.sh`,
`check_examples_self_contained.sh`, `check_operator_diagnostics.py` and
`check_json_decode_boundary.sh` all pass.

**TypeScript parity:** No language-parity impact — shared CLI argument transport changes
no application or framework contract.
