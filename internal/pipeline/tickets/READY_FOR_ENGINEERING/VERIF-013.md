---
id: VERIF-013
type: bug
severity: high
title: A premise probe that cannot run is reported as a verdict
source: internal/pipeline/audits/2026-10-01_verification_architecture_audit.md
---

A premise probe that cannot run is reported as a verdict

**Depends on:** None.

**Premise re-verified (2026-10-01)** against `origin/main @ fd138b3a`:
`internal/tooling/soldev/lib/soldev_ticket.ml:332-340` maps a probe's exit status with

```ocaml
let premise_verdict ~exit_code =
  if exit_code = 0 then Premise_stale
  else if exit_code = 127 then Premise_unverified "the probe command was not found (exit 127)"
  else if exit_code = 126 then Premise_unverified "the probe command is not executable (exit 126)"
  else Premise_holds
;;
```

so every exit code outside `{0, 126, 127}` — including a probe that could not run to a conclusion —
is reported as `Premise_holds` and rendered `actionable` by `pipeline ls`
(`internal/tooling/soldev/lib/soldev_merge.ml:944-956`, `:1072-1091`). Observed on the current tree,
with the path having moved in REFAC-104:

```
$ rg -q Byo cli/sol/lib/sol_cli_open.ml;  echo $?      # BACKLOG/OBS-045's probe
2
$ ! rg -q Byo cli/sol/lib/sol_cli_open.ml; echo $?     # DONE/OBS-046's probe, same gone path
0                     # => Premise_stale: "nothing there" from a read that never happened
$ soldev pipeline ls | grep OBS-045
  OBS-045  feature  medium  depends on: none  needs-human  Open traces for a Sol scope …
```

`rg` exits 2 for "I could not read what you asked for" and 1 for "no match"; the mechanism
special-cases only 126 and 127. A moved path, a shell syntax error or a permission failure is
therefore reported as a confident verdict, in one of two wrong directions: `Premise_holds`, so the
ticket stays actionable forever and nobody learns the probe is broken, or — for the negated form the
convention requires when the fix removed something — `Premise_stale`, so a ticket whose probe cannot
run is marked done and quietly disappears from the queue. Both are live: `OBS-045` is in the first
state (masked only by its `needs-human` section) and `DONE/OBS-046` carries the second form against
the same gone path.

This is the failure class the rest of the verification audit is about, inside the tooling that
decides whether a ticket is actionable: an inaccurate observation presented as a confident one.

## Desired invariant

A probe has exactly three outcomes, and "did not reach a conclusion" is never one of the two
verdicts. The contract is stated where probes are documented: exit 0 ⇒ premise stale, exit 1 ⇒
premise holds, any other exit ⇒ unverified, with the exit code and the probe's output shown so the
operator can see what happened.

## Remediation

Treat every exit outside `{0, 1}` as `Premise_unverified`, carrying the code and the probe's stderr
in the reason. Because the common cause is a probe naming a path that moved, report the paths a
probe names that do not exist in the tree — the same "a named path must exist" invariant
`internal/ci/check_workflow_paths.py` already applies to workflow `paths:` filters, applied to
premise probes. Re-verify existing probes as part of this change: `OBS-045`'s and `OBS-046`'s both
name `cli/sol/lib/sol_cli_open.ml`, which no longer exists.

## Acceptance criteria

- A probe exiting 2 (a missing file, or a shell error) reports `premise-unverified` naming the exit
  code, and `pipeline ls` shows it as unverified rather than actionable.
- A negated probe over a path that does not exist does not report `premise-stale`.
- The probe contract — 0 stale, 1 holds, anything else unverified — is stated where probes are
  documented, next to the example probe.
- Every existing probe that names a repository path is checked against the tree, and the two that
  name the moved `cli/sol/lib/sol_cli_open.ml` are corrected or rewritten as a symbol probe.
- Mutation coverage: a case plants a probe with a nonexistent path and a case plants one with a
  shell syntax error, and both are reported unverified.
- Demo/example: not applicable — pipeline tooling. Language parity: not applicable; state it in one
  line.
