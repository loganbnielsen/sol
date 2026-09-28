---
id: REFAC-151
type: refactor
severity: low
title: Bounded CLI commands return typed outcomes before rendering them
source: Logan code review (2026-09-27), generalized from cmd_alert and cmd_assets
---

Bounded CLI commands return typed outcomes before rendering them

**Depends on:** None.

**Premise verified (2026-09-27):** `cmd_alert.ml`'s `report_outcome` both interprets and
prints an outcome; `cmd_assets.ml` computes, renders, prints, and decides failure inside
`run`; `cmd_check.ml`, `cmd_plan.ml`, `cmd_target.ml`, `cmd_releases.ml`, and
`cmd_deployments.ml` are other bounded commands that can be reviewed against the same
operation → outcome → rendering → terminal-effect shape. REFAC-135 removed printing
from `cli/lib`, and REFAC-139 moved decisions out of four large commands, but neither
audited this remaining `cli/bin` category.

## The principle

For a bounded command whose operation finishes before output begins:

1. the operation returns structured data or a typed outcome;
2. semantic failure is decided where that outcome is built;
3. rendering converts the outcome to text;
4. the outer command/controller owns stdout/stderr and exit conversion.

Do not force this shape onto progress output, prompts, streaming logs, child-process
forwarding, or other operations whose terminal effect is part of execution. Do not add
`print_*` wrappers that merely hide the effect one function deeper.

## Remediation

- Inventory bounded commands in `cli/bin` and classify each as bounded presentation or
  inherently streaming/effectful.
- Apply the typed-outcome boundary to high-confidence bounded commands, starting with
  the `alert` and `assets` examples, and reuse existing domain outcomes/renderers.
- Put semantic decisions in `cli/lib` only when they are domain behavior; keep thin
  presentation records local when no library consumer needs them.
- Add the bounded-versus-streaming distinction to the command convention in
  `CONTRIBUTING.md`.

## Acceptance criteria

- Completion notes inventory every `cli/bin` command with a bounded/streaming verdict;
  silence is not a verdict.
- High-confidence bounded commands have directly testable operation outcomes and pure
  rendering before the controller prints.
- Streaming/progress commands retain their effects, with the reason recorded; no fake
  buffering is introduced merely to satisfy the pattern.
- User-visible output and exit codes are byte-for-byte unchanged in real-command tests.
- Demo/example: not applicable unless a changed command alters app-author behavior.
- Language parity: no impact; this is CLI implementation structure.

