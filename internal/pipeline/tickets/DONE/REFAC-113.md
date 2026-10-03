---
id: REFAC-113
type: refactor
severity: low
title: Decide whether Sol_cli_process should sit on bos instead of hand-rolled Unix process handling
source: operator code-review notes (2026-09-25, sol-logan-review), cli/lib/base/sol_cli_process.ml:158
---

**Depends on:** None.

## The question

`cli/lib/base/sol_cli_process.ml` (251 lines, used at ~510 `Sol_cli_process.`
references across `cli/`) hand-rolls spawning, capturing and waiting on
subprocesses over `Unix`. `bos` (the de facto basic-OS library) is already in the
switch as a transitive dependency of `yaml` (REFAC-106), and `spawn` is also
installed.

`bos` covers spawning and capture. It does **not** cover the two things this
module exists for:

- **timeouts**, which the cloud lifecycle relies on so a hung `terraform`/`kubectl`
  can't hang `sol`;
- **redaction** of secrets from echoed commands and error text (SEC-010).

So adopting `bos` would mean "bos plus our timeout and redaction layer", not
deleting the module. That trims perhaps half of it at the cost of a direct
dependency and a behavioural re-verification of every lifecycle path.

## Open Questions

1. Is the reduction in hand-written code worth a direct `bos` dependency and a
   re-qualification of process behaviour (signals on timeout, stderr
   interleaving, exit-code mapping)?
2. If yes, is `bos` (`Bos.OS.Cmd`) or the lower-level `spawn` the better base,
   given that timeouts need the child's pid?

## Acceptance criteria (once decided)

- [ ] Either the decision "keep hand-rolled" is recorded here with the reason and
      the ticket closed, or the core is replaced with the public
      `Sol_cli_process` API unchanged, and timeout and redaction tests still pass.

## Disposition (2026-10-03) — decision required

Smallest decision: adopt `bos`/`spawn` for `Sol_cli_process` or keep the hand-rolled Unix module. Consequence: `bos` does not cover timeouts or SEC-010 redaction, so adoption trims about half the module at the cost of a direct dependency and a behavioural re-verification of every lifecycle path.

Surfaced to the operator as a category-5 decision; not deferred. Moves to
`READY_FOR_ENGINEERING/` once the decision is recorded. See
`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`.


## Decision (2026-10-03) — keep the hand-rolled process module

Decided by this pass: **Keep `Sol_cli_process`.** `bos` covers spawning and
capture but not the two things the module exists for — timeouts (a hung
`terraform`/`kubectl` must not hang `sol`) and SEC-010 redaction of secrets from
echoed commands and error text. Adopting `bos` would be "bos plus our timeout and
redaction layer", trimming about half the module at the cost of a direct
dependency and a behavioural re-verification of every lifecycle path — not worth
it while the module is correct. Promoted to `READY_FOR_ENGINEERING` only so the
transition guard can close it as "no change".


## Closed (2026-10-03) — decided no change

Keep the hand-rolled `Sol_cli_process`: `bos`/`spawn` cover spawning and capture
but not the module's two reasons to exist — timeouts (a hung
`terraform`/`kubectl` must not hang `sol`) and SEC-010 redaction. Adoption would
be "bos plus our timeout and redaction layer" at the cost of a direct dependency
and a behavioural re-verification of every lifecycle path. Decision recorded in
the adjudication ledger.
