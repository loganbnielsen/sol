---
id: DOCS-030
type: documentation
severity: medium
title: Provide a CLI reference for every command, flag, and exit behaviour
source: docs/README.md documentation roadmap (2026-09-29)
---

**Depends on:** None.

**Related:** `docs/architecture/devops-pipeline.md` (the narrative of what each
command does), `docs/guides/TUTORIAL.md`'s CLI reference section,
`DEC-031`/`DEC-032` (the primary-axis rule the reference must present
consistently), `DOCS-026`/`DOCS-028`/`DOCS-029` (the task guides that link to
entries here).

## What this page is

A single reference for the `sol` command surface: every registered command, its
positional and flags, the scopes it accepts, and what exit status means. Today the
only reference is the tutorial's "CLI reference" comment block, which is partial
and mixes explanation with the walkthrough.

The value is not exhaustiveness for its own sake. Several rules are easy to get
wrong and hard to rediscover — which axis takes the positional, which commands
accept which scopes, and which commands are deliberately narrow (`sol logs` is
unit-only). A reference states them once.

## Audience

Any user who knows what they want to do and needs the exact spelling; and a
contributor checking that a new command follows the house rules.

## Content requirements

- **Every registered command**, grouped by primary axis: target-addressed
  (`sol deploy`, `sol up`, `sol cloud plan|apply|destroy`, `sol plan`),
  scope-addressed (`sol status`, `sol open`), and local (`sol local …`).
- For each command: the positional, the flags, accepted scopes/targets, and a
  one-line purpose.
- **Accepted scopes stated per command**, since they are deliberately not
  uniform, with the reason for the narrow ones.
- **Exit behaviour**: what a non-zero exit means, and the fail-closed cases a
  script can rely on.
- **The addressing rule**, stated once and linked from the task guides
  (`DEC-031`, `DEC-032`).
- Where a command's output has a machine-readable form (`--json`, plan output),
  say so.

## Sources of truth to link, not copy

- The command registration in `cli/bin/`.
- The axis rule: `DEC-031`, `DEC-032`.
- The narrative explanation: `docs/architecture/devops-pipeline.md`.

## Acceptance criteria

- Every command registered in `cli/bin/` appears, verified by comparing against
  the binary's own help rather than by memory.
- The reference cannot silently drift: a guard (or a test) compares the documented
  command set against the registered set and fails on a new undocumented command.
- Each command states its accepted scopes, and the rule behind the non-uniform set
  is linked.
- No command is documented with a flag it does not have; Target commands are
  marked with their ticket.
- `docs/README.md` marks this page Published.

## Notes

- Prefer generating the mechanical parts (command and flag names) from the CLI
  itself and keeping the prose curated, so drift is a test failure rather than a
  docs audit finding.

## Completion notes (2026-09-30)

`docs/reference/cli.md` is published, and the mechanical part of it is generated rather than
written by hand.

**Every registered command, verified against the binary** (AC1). The page documents **46**
commands, and the list is not typed by a human: `internal/ci/lib/cli_surface.py` walks
`sol <command> --help=plain` recursively from the root, so the command set, each positional,
each flag spelling (including whether it takes a value) and whether the command's help carries
an `EXIT STATUS` section all come from the binary. Spot-checking the walker against an
independently written extractor found one bug in it — a wrapped synopsis line
(`[--target=ENV/PROVIDER/REGION]`) was being read as a command name — which is why the walker
now accepts only `^[a-z][a-z0-9-]*$` as a command name.

**The page cannot silently drift** (AC2). `internal/ci/check_cli_reference.py` fails when the
page and the binary disagree, in both directions: an undocumented command, a documented
command the binary does not register, and a *flag* documented for a command that does not have
it. `internal/tooling/scripts/render-cli-reference.py` regenerates the four generated blocks
(the prose is curated and outside them), and both run in CI as a guard step plus its mutation
test. The mutation test was written first and caught two real bugs in the guard: the expected
command set was being derived from the page it was checking, and the flags column was being
read from the wrong cell.

**Recorded gap.** The repo's docs-only fast path deliberately skips every guard
(`check_unconditional_guard_tooling.py` fixes the two permitted step conditions), so a
docs-only PR that hand-edits the page is not caught by CI. A code change to the CLI surface
is, which is the drift the criterion is about; the hand-edit case is covered by review rather
than pretending the guard sees it.

**Scope: the non-uniform set, stated once** (AC3). The page states the primary-axis rule
(DEC-031/DEC-032) with the examples that look inconsistent and are not, and the scope set with
the deliberate exceptions — `sol logs` is unit-only, `sol status`/`sol open` take the four
forms, the `--scope` commands resolve `domain` and `domain/unit`. Where a fact is a rule
rather than a spelling, the page links the record instead of restating it.

**No invented flags** (AC4). The flag column is generated, so a flag that does not exist
cannot be written; the guard fails on one anyway (mutation case three). `docs/README.md` now
marks the page Published (AC5), and the commands that are planned rather than registered are
listed with their tickets (FEAT-106, FEAT-107, FEAT-108, FEAT-109).

**Demo/example coverage:** none applies — this ticket adds a reference page and a guard, and
changes no app-author surface (`sol.toml`, a framework primitive, a generated manifest, or a
command's behaviour).

**Language parity:** no impact. The reference describes the CLI, which is language-neutral;
no application-facing contract changed.
