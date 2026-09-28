---
id: REFAC-144
type: refactor
severity: low
title: Make sol assets read as named checks followed by one report
source: Logan code review (2026-09-27)
---

Make `sol assets` read as named checks followed by one report

**Depends on:** None.

**Premise verified (2026-09-27):** read `cmd_assets.ml` on `origin/main` at
`954afad7`; all three dense shapes described below are present.

**Problem:** `cli/bin/cmd_assets.ml` hides several conceptually distinct values inside
larger applications: `component_checks` passes a two-profile `let*` chain directly to
`check`, `template_checks` passes a multi-arm match directly to `check`, and `checks`
builds provider, component, template, and observability groups inside one nested
`List.concat`. The code is correct, but the reader must hold the outer call open while
working through each inner computation. The two component calls are especially opaque:
they deliberately verify both the `local` and `durable` profiles, but the first result is
discarded and the reason for the pair is only inferable from the literals.

The command's printing is already at the command boundary. Do not introduce a report
abstraction or pure renderers solely to move those effects one function away.

## Remediation

- Name the outcome before passing it to `check` when producing it takes a multi-line
  control-flow expression.
- Express the supported component profiles as the small fixed collection they are and
  check both through one obvious path.
- Name the provider-root and observability groups so the final `checks` expression is a
  high-level list of groups.
- Keep `run` as the command/controller boundary and preserve terminal output byte for
  byte.

## Acceptance criteria

- `component_checks`, `template_checks`, and `checks` read top to bottom without a
  multi-line `match`, `if`, or `let*` expression embedded as a call argument.
- Both `local` and `durable` component values are still checked.
- A focused command test proves success/failure output and exit behavior are unchanged.
- Demo/example: not applicable; this changes an install diagnostic's internal shape.
- Language parity: no impact; the command checks language-neutral platform assets.
